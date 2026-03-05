#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl

require_context "$CTX_EAST"
require_context "$CTX_WEST"

NS="${NS:-bookinfo}"

patch_scrape_annotations() {
  local ctx="$1" deploy="$2" ns="$3"
  kubectl --context "$ctx" -n "$ns" patch "deploy/${deploy}" --type merge -p '{
    "spec": {
      "template": {
        "metadata": {
          "annotations": {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": "15090",
            "prometheus.io/path": "/stats/prometheus"
          }
        }
      }
    }
  }' >/dev/null
}

main() {
  log "=== Enable Prometheus scraping for Istio waypoints/gateway ==="
  log "Contexts: east=${CTX_EAST}, west=${CTX_WEST}"
  log "Namespace: ${NS}"
  log ""

  for ctx in "$CTX_EAST" "$CTX_WEST"; do
    log "Patching deployments on ${ctx}..."
    for d in bookinfo-gateway-istio productpage-waypoint reviews-waypoint ratings-waypoint details-waypoint; do
      patch_scrape_annotations "$ctx" "$d" "$NS"
    done
    for d in bookinfo-gateway-istio productpage-waypoint reviews-waypoint ratings-waypoint details-waypoint; do
      kubectl --context "$ctx" -n "$NS" rollout status "deploy/${d}" --timeout=180s >/dev/null
    done
  done

  log ""
  log "Done. Prometheus should start scraping in ~15-30s."
}

main "$@"

