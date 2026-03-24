#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
need oc

require_context "$CTX_EAST"
require_context "$CTX_WEST"

download_istioctl

BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
BOOKINFO_WAYPOINTS_ENABLED="${BOOKINFO_WAYPOINTS_ENABLED:-false}"

bookinfo_overlay_dir() {
  if [[ "${BOOKINFO_WAYPOINTS_ENABLED}" == "true" ]]; then
    echo "${ROOT_DIR}/apps/bookinfo/overlays/istio129-mc-waypoints"
  else
    echo "${ROOT_DIR}/apps/bookinfo/overlays/istio129-mc"
  fi
}

apply_bookinfo() {
  local ctx="$1"
  log "Deploying Bookinfo manifests on ${ctx}..."
  kubectl --context "$ctx" apply -k "$(bookinfo_overlay_dir)" >/dev/null
}

apply_waypoints() {
  local ctx="$1"
  log "Creating per-service waypoints on ${ctx}..."
  for wp in productpage-waypoint reviews-waypoint ratings-waypoint details-waypoint; do
    # On OpenShift, service traffic may appear as "workload" at interception time (DNAT),
    # so we use --for all to ensure waypoint transit is enforced.
    istioctl --context "$ctx" waypoint apply -n "$BOOKINFO_NS" --for all --name "$wp" >/dev/null || true
  done
}

grant_anyuid_scc() {
  local ctx="$1"
  # Waypoint/gateway deployments run with fixed UID (1337) and need anyuid SCC on OpenShift.
  for sa in bookinfo-gateway-istio productpage-waypoint reviews-waypoint ratings-waypoint details-waypoint; do
    oc --context "$ctx" adm policy add-scc-to-user anyuid -n "$BOOKINFO_NS" -z "$sa" >/dev/null 2>&1 || true
  done
}

patch_clustername_env() {
  local ctx="$1"
  local cluster="$2"
  log "Patching CLUSTER_NAME env on ${ctx} (reviews + ratings)..."
  for d in reviews-v1 reviews-v2 reviews-v3 ratings-v1; do
    kubectl --context "$ctx" -n "$BOOKINFO_NS" set env "deploy/${d}" CLUSTER_NAME="${cluster}" >/dev/null
  done
}

wait_rollout() {
  local ctx="$1"
  log "Waiting for Bookinfo workloads on ${ctx}..."
  local deployments=(bookinfo-gateway-istio details-v1 productpage-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3)
  if [[ "${BOOKINFO_WAYPOINTS_ENABLED}" == "true" ]]; then
    deployments+=(productpage-waypoint reviews-waypoint ratings-waypoint details-waypoint)
  fi
  local d
  for d in "${deployments[@]}"; do
    kubectl --context "$ctx" -n "$BOOKINFO_NS" rollout status "deploy/${d}" --timeout=180s >/dev/null
  done
}

main() {
  log "=== Deploy Bookinfo (Istio 1.29 ambient) ==="
  log "Contexts: east=${CTX_EAST}, west=${CTX_WEST}"
  log "Waypoints enabled: ${BOOKINFO_WAYPOINTS_ENABLED}"
  log ""

  apply_bookinfo "$CTX_EAST"
  apply_bookinfo "$CTX_WEST"

  if [[ "${BOOKINFO_WAYPOINTS_ENABLED}" == "true" ]]; then
    apply_waypoints "$CTX_EAST"
    apply_waypoints "$CTX_WEST"

    grant_anyuid_scc "$CTX_EAST"
    grant_anyuid_scc "$CTX_WEST"
  fi

  patch_clustername_env "$CTX_EAST" "$CTX_EAST"
  patch_clustername_env "$CTX_WEST" "$CTX_WEST"

  wait_rollout "$CTX_EAST"
  wait_rollout "$CTX_WEST"

  log ""
  log "Bookinfo deployed."
  log "Next demos:"
  log "  CTX_EAST=${CTX_EAST} ./scripts/istio129/demo-traffic-shift.sh"
  log "  CTX_EAST=${CTX_EAST} CTX_WEST=${CTX_WEST} ./scripts/istio129/demo-failover.sh"
}

main "$@"

