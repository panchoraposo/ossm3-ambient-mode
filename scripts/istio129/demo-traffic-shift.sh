#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
require_context "$CTX_EAST"

NS="${NS:-bookinfo}"
CURL_POD="${CURL_POD:-demo-curl}"
SAMPLES_1="${SAMPLES_1:-60}"
SAMPLES_2="${SAMPLES_2:-120}"
DEMO_MODE="${DEMO_MODE:-kiali}" # kiali | fast
HOLD_SECONDS_1="${HOLD_SECONDS_1:-60}"
HOLD_SECONDS_2="${HOLD_SECONDS_2:-60}"
HOLD_SECONDS_3="${HOLD_SECONDS_3:-60}"
LOAD_SLEEP_SECONDS="${LOAD_SLEEP_SECONDS:-0.05}"
PROGRESS_EVERY_SECONDS="${PROGRESS_EVERY_SECONDS:-20}"

ensure_reviews_replicas() {
  log "Ensuring reviews-v1 and reviews-v2 are running (replicas=1)..."
  for d in reviews-v1 reviews-v2; do
    kubectl --context "$CTX_EAST" -n "$NS" get "deploy/${d}" >/dev/null 2>&1 || die "Missing deployment: ${NS}/${d}"
    kubectl --context "$CTX_EAST" -n "$NS" scale "deploy/${d}" --replicas=1 >/dev/null
  done
  for d in reviews-v1 reviews-v2; do
    kubectl --context "$CTX_EAST" -n "$NS" rollout status "deploy/${d}" --timeout=180s >/dev/null
  done
}

ensure_reviews_use_waypoint() {
  # On some OpenShift CNI/DNAT paths, service traffic can be observed as "workload IP" at interception time.
  # In that case, only labeling the Service is not enough: we must bind the destination workloads to the waypoint.
  log "Ensuring reviews workloads use waypoint..."
  kubectl --context "$CTX_EAST" -n "$NS" label sa bookinfo-reviews istio.io/use-waypoint=reviews-waypoint istio.io/use-waypoint-namespace="$NS" --overwrite >/dev/null 2>&1 || true
  for d in reviews-v1 reviews-v2 reviews-v3; do
    kubectl --context "$CTX_EAST" -n "$NS" patch "deploy/${d}" --type merge -p "{
      \"spec\": {\"template\": {\"metadata\": {\"labels\": {
        \"istio.io/use-waypoint\": \"reviews-waypoint\",
        \"istio.io/use-waypoint-namespace\": \"${NS}\"
      }}}}
    }" >/dev/null
  done
  for d in reviews-v1 reviews-v2 reviews-v3; do
    kubectl --context "$CTX_EAST" -n "$NS" rollout status "deploy/${d}" --timeout=180s >/dev/null
  done
}

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
  log "Creating curl pod ${NS}/${CURL_POD}..."
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

sample_versions() {
  local n="$1"
  kubectl --context "$CTX_EAST" exec -n "$NS" "$CURL_POD" -- sh -c "
    i=0
    while [ \$i -lt $n ]; do
      v=\$(curl -sS --max-time 3 http://reviews:9080/reviews/0 2>/dev/null | grep -oE 'reviews-v[0-9]' | head -1 || true)
      echo \${v:-?}
      i=\$((i+1))
      sleep 0.05
    done
  " | sort | uniq -c | sed 's/^ *//'
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

  local pid start now next end
  pid="$(start_load "$seconds")"
  start="$(date +%s)"
  end=$((start + seconds))
  next=$((start + PROGRESS_EVERY_SECONDS))

  while kill -0 "$pid" >/dev/null 2>&1; do
    now="$(date +%s)"
    if [[ "$now" -ge "$next" ]]; then
      log "[Kiali] ${label}: quick sample (20 req):"
      sample_versions 20
      next=$((now + PROGRESS_EVERY_SECONDS))
    fi
    sleep 1
  done
  wait "$pid" >/dev/null 2>&1 || true
  log "[Kiali] ${label}: done."
}

get_count() {
  local label="$1"
  awk -v l="$label" '$2==l {print $1}' | head -1
}

validate_split_counts() {
  local n="$1" expect_v1="$2" expect_v2="$3" forbid_v3="$4"
  local out c1 c2 c3
  out="$(sample_versions "$n")"
  echo "$out"

  c1="$(printf '%s\n' "$out" | get_count "reviews-v1")"; c1="${c1:-0}"
  c2="$(printf '%s\n' "$out" | get_count "reviews-v2")"; c2="${c2:-0}"
  c3="$(printf '%s\n' "$out" | get_count "reviews-v3")"; c3="${c3:-0}"

  if [[ "$forbid_v3" == "1" && "$c3" -gt 0 ]]; then
    die "Observed reviews-v3 (${c3}) — routing did not take effect (expected only v1/v2)."
  fi

  if [[ "$expect_v1" == "1" && "$c1" -lt 1 ]]; then
    die "Did not observe reviews-v1 — routing/waypoint may not be in effect."
  fi
  if [[ "$expect_v2" == "1" && "$c2" -lt 1 ]]; then
    die "Did not observe reviews-v2 — routing/waypoint may not be in effect."
  fi
}

cleanup_old_route_objects() {
  # Older iterations used Gateway API HTTPRoute for splitting; remove it to avoid confusion.
  kubectl --context "$CTX_EAST" -n "$NS" delete httproute reviews-traffic-split --ignore-not-found >/dev/null 2>&1 || true
  # Cleanup older iterations that created separate *-failover DestinationRules (Kiali will warn about duplicates).
  kubectl --context "$CTX_EAST" -n "$NS" delete destinationrule reviews-failover ratings-failover --ignore-not-found >/dev/null 2>&1 || true
}

apply_reviews_destinationrule() {
  # VirtualService uses subsets v1/v2; ensure DestinationRule defines them.
  kubectl --context "$CTX_EAST" apply -n "$NS" -f - >/dev/null <<EOF
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
      consecutive5xxErrors: 3
      consecutiveGatewayErrors: 3
      interval: 5s
      baseEjectionTime: 30s
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failoverPriority:
          - topology.istio.io/cluster
EOF
}

apply_virtualservice_split() {
  local w1="$1" w2="$2"
  log "Applying split ${w1}/${w2} to VirtualService reviews-split (subsets v1/v2)..."
  kubectl --context "$CTX_EAST" apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-split
spec:
  hosts:
    - reviews.${NS}.svc.cluster.local
  http:
    - route:
        - destination:
            host: reviews.${NS}.svc.cluster.local
            subset: v1
          weight: ${w1}
        - destination:
            host: reviews.${NS}.svc.cluster.local
            subset: v2
          weight: ${w2}
EOF
}

main() {
  log "=== Demo: Traffic shifting on waypoint (Istio ${ISTIO_VERSION}, ${CTX_EAST}) ==="
  log "This test calls reviews directly from an in-mesh curl pod."
  log "Mode: ${DEMO_MODE}"
  if [[ "$DEMO_MODE" == "kiali" ]]; then
    log ""
    log "Kiali quick checklist (to avoid an empty graph):"
    log "  - Graph -> Namespace: ${NS}"
    log "  - Cluster selector: ${CTX_EAST} (or 'All clusters' if available)"
    log "  - Time range: Last 10m"
    log "  - Traffic selectors: include Waypoint (L7). If you only select Source/Destination, graph may be empty in Ambient."
    log "  - If still empty: enable 'Idle nodes/edges' display and clear any 'Hide' filters."
  fi
  log ""

  ensure_curl_pod
  ensure_reviews_replicas
  ensure_reviews_use_waypoint
  cleanup_old_route_objects
  apply_reviews_destinationrule

  apply_virtualservice_split 90 10
  sleep 3
  if [[ "$DEMO_MODE" == "kiali" ]]; then
    hold_with_progress "$HOLD_SECONDS_1" "Phase 1 (90/10)"
  fi
  log "Sampling ${SAMPLES_1} requests (expect mostly v1, some v2, and no v3):"
  validate_split_counts "$SAMPLES_1" 1 1 1
  log ""

  apply_virtualservice_split 50 50
  sleep 3
  if [[ "$DEMO_MODE" == "kiali" ]]; then
    hold_with_progress "$HOLD_SECONDS_2" "Phase 2 (50/50)"
  fi
  log "Sampling ${SAMPLES_2} requests (expect ~50/50 v1/v2, and no v3):"
  validate_split_counts "$SAMPLES_2" 1 1 1
  log ""

  apply_virtualservice_split 0 100
  sleep 3
  if [[ "$DEMO_MODE" == "kiali" ]]; then
    hold_with_progress "$HOLD_SECONDS_3" "Phase 3 (0/100)"
  fi
  log "Sampling ${SAMPLES_1} requests (expect only v2, and no v3):"
  local out c1 c2 c3
  out="$(sample_versions "$SAMPLES_1")"
  echo "$out"
  c1="$(printf '%s\n' "$out" | get_count "reviews-v1")"; c1="${c1:-0}"
  c2="$(printf '%s\n' "$out" | get_count "reviews-v2")"; c2="${c2:-0}"
  c3="$(printf '%s\n' "$out" | get_count "reviews-v3")"; c3="${c3:-0}"
  if [[ "$c3" -gt 0 ]]; then
    die "Observed reviews-v3 (${c3}) — routing did not take effect (expected only v2)."
  fi
  if [[ "$c1" -gt 0 || "$c2" -lt 1 ]]; then
    die "Expected only reviews-v2, but observed v1=${c1}, v2=${c2}."
  fi
  log ""

  log "Done."
  log "Tip: open Kiali and watch edges between reviews-waypoint -> reviews-v1/v2."
}

main "$@"

