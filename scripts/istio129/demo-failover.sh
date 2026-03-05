#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
require_context "$CTX_EAST"
require_context "$CTX_WEST"

NS="${NS:-bookinfo}"
CURL_POD="${CURL_POD:-demo-curl}"
DEMO_MODE="${DEMO_MODE:-kiali}" # kiali | fast
PRE_HOLD_SECONDS="${PRE_HOLD_SECONDS:-45}"
POST_HOLD_SECONDS="${POST_HOLD_SECONDS:-90}"
LOAD_SLEEP_SECONDS="${LOAD_SLEEP_SECONDS:-0.05}"
PROGRESS_EVERY_SECONDS="${PROGRESS_EVERY_SECONDS:-20}"

ensure_curl_pod() {
  if kubectl --context "$CTX_EAST" get pod -n "$NS" "$CURL_POD" >/dev/null 2>&1; then
    local phase ready
    phase="$(kubectl --context "$CTX_EAST" get pod -n "$NS" "$CURL_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    ready="$(kubectl --context "$CTX_EAST" get pod -n "$NS" "$CURL_POD" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    if [[ "$phase" == "Running" && "$ready" == "True" ]]; then
      return 0
    fi
    log "Recreating curl pod ${NS}/${CURL_POD} (phase=${phase}, ready=${ready})..."
    kubectl --context "$CTX_EAST" delete pod -n "$NS" "$CURL_POD" --ignore-not-found >/dev/null
  fi
  log "Creating curl pod ${NS}/${CURL_POD} on ${CTX_EAST}..."
  kubectl --context "$CTX_EAST" apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${CURL_POD}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl:latest
      command: ["sh","-c","sleep 3650000"]
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
EOF
  kubectl --context "$CTX_EAST" wait -n "$NS" --for=condition=Ready "pod/${CURL_POD}" --timeout=120s >/dev/null
}

cleanup_traffic_shift() {
  # Ensure the failover demo isn't affected by traffic-shifting config.
  kubectl --context "$CTX_EAST" -n "$NS" delete virtualservice reviews-split --ignore-not-found >/dev/null 2>&1 || true
}

apply_failover_destinationrules() {
  # In ambient multicluster, the waypoint needs an explicit DestinationRule with outlierDetection
  # to enable failover behavior (see Istio docs: ambient/install/multicluster/failover).
  for ctx in "$CTX_EAST" "$CTX_WEST"; do
    # Cleanup older iterations that created separate *-failover DestinationRules (Kiali will warn about duplicates).
    kubectl --context "$ctx" -n "$NS" delete destinationrule reviews-failover ratings-failover --ignore-not-found >/dev/null 2>&1 || true
    log "Applying failover DestinationRules on ${ctx}..."
    kubectl --context "$ctx" apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews.${NS}.svc.cluster.local
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
    - name: v3
      labels:
        version: v3
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 1m
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failoverPriority:
          - topology.istio.io/cluster
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ratings
spec:
  host: ratings.${NS}.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 1m
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failoverPriority:
          - topology.istio.io/cluster
EOF
  done
}

get_clustername() {
  # returns "east2"/"west2" (or empty on error)
  kubectl --context "$CTX_EAST" exec -n "$NS" "$CURL_POD" -- sh -c \
    "curl -sS --max-time 3 http://reviews:9080/reviews/0 2>/dev/null | tr -d '\\n' | sed -n 's/.*\"clustername\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'"
}

scale_reviews_ratings() {
  local ctx="$1" replicas="$2"
  for d in reviews-v1 reviews-v2 reviews-v3 ratings-v1; do
    kubectl --context "$ctx" -n "$NS" scale "deploy/${d}" --replicas="${replicas}" >/dev/null 2>&1 || true
  done
}

wait_no_pods() {
  local ctx="$1"
  for _ in {1..60}; do
    local c
    c="$(kubectl --context "$ctx" get pods -n "$NS" -l 'app in (reviews,ratings)' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$c" == "0" ]] && return 0
    sleep 2
  done
  return 1
}

count_clustername_matches() {
  local want="$1" n="$2"
  local i cn hits=0 empties=0
  for ((i=1; i<=n; i++)); do
    cn="$(get_clustername || true)"
    if [[ -z "${cn:-}" ]]; then
      empties=$((empties+1))
    elif [[ "$cn" == "$want" ]]; then
      hits=$((hits+1))
    fi
    sleep 0.5
  done
  printf '%s %s\n' "$hits" "$empties"
}

start_load() {
  local seconds="$1"
  kubectl --context "$CTX_EAST" exec -n "$NS" "$CURL_POD" -- sh -c "
    end=\$((\$(date +%s) + ${seconds}))
    while [ \$(date +%s) -lt \$end ]; do
      curl -sS --max-time 3 http://reviews:9080/reviews/0 >/dev/null 2>&1 || true
      sleep ${LOAD_SLEEP_SECONDS}
    done
  " >/dev/null 2>&1 &
  echo $!
}

hold_with_progress() {
  local seconds="$1" label="$2"
  log ""
  log "[Kiali] ${label}: generating traffic for ~${seconds}s. Open Kiali Graph now."

  local pid start now next
  pid="$(start_load "$seconds")"
  start="$(date +%s)"
  next=$((start + PROGRESS_EVERY_SECONDS))

  while kill -0 "$pid" >/dev/null 2>&1; do
    now="$(date +%s)"
    if [[ "$now" -ge "$next" ]]; then
      local hits empties
      read -r hits empties < <(count_clustername_matches "$CTX_EAST" 6)
      log "[Kiali] ${label}: east2 matches=${hits}/6 empty=${empties}/6"
      read -r hits empties < <(count_clustername_matches "$CTX_WEST" 6)
      log "[Kiali] ${label}: west2 matches=${hits}/6 empty=${empties}/6"
      next=$((now + PROGRESS_EVERY_SECONDS))
    fi
    sleep 1
  done
  wait "$pid" >/dev/null 2>&1 || true
  log "[Kiali] ${label}: done."
}

main() {
  log "=== Demo: Cross-cluster failover (Istio ${ISTIO_VERSION}, ${CTX_EAST} -> ${CTX_WEST}) ==="
  log "Mode: ${DEMO_MODE}"
  if [[ "$DEMO_MODE" == "kiali" ]]; then
    log ""
    log "Kiali quick checklist (to avoid an empty graph):"
    log "  - Graph -> Namespace: ${NS}"
    log "  - Cluster selector: switch between ${CTX_EAST} and ${CTX_WEST} (or use 'All clusters' if available)"
    log "  - Time range: Last 10m"
    log "  - Traffic selectors: include Waypoint (L7) for HTTP traffic in Ambient."
    log "  - If still empty: enable 'Idle nodes/edges' display and clear any 'Hide' filters."
  fi
  log ""

  ensure_curl_pod
  cleanup_traffic_shift
  apply_failover_destinationrules

  log "Baseline: calls from ${CTX_EAST} to reviews should be served by ${CTX_EAST}."
  local i cn
  for i in 1 2 3; do
    cn="$(get_clustername || true)"
    log "  request ${i}: clustername=${cn:-<empty>}"
    sleep 1
  done

  if [[ "$DEMO_MODE" == "kiali" ]]; then
    hold_with_progress "$PRE_HOLD_SECONDS" "Phase 1 (baseline on east2)"
  fi
  log ""

  log "Scaling reviews+ratings to 0 on ${CTX_EAST}..."
  scale_reviews_ratings "$CTX_EAST" 0
  if ! wait_no_pods "$CTX_EAST"; then
    die "East pods did not scale to 0 (still running)."
  fi
  log "Scaled down on ${CTX_EAST}."
  log ""

  log "Failover check: calls from ${CTX_EAST} should now be served by ${CTX_WEST}."
  local hits empties
  read -r hits empties < <(count_clustername_matches "$CTX_WEST" 12)
  log "  matches(${CTX_WEST})=${hits}/12, empty_responses=${empties}/12"
  if [[ "$hits" -lt 1 ]]; then
    die "Failover did not occur (no responses served by ${CTX_WEST})."
  fi

  if [[ "$DEMO_MODE" == "kiali" ]]; then
    hold_with_progress "$POST_HOLD_SECONDS" "Phase 2 (after failover to west2)"
  fi
  log ""

  log "Restoring ${CTX_EAST}..."
  scale_reviews_ratings "$CTX_EAST" 1
  log "Done."
}

main "$@"

