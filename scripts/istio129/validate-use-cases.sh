#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
need oc

require_context "$CTX_EAST"
require_context "$CTX_WEST"

NS="${NS:-bookinfo}"

ensure_bookinfo_present() {
  if kubectl --context "$CTX_EAST" get ns "$NS" >/dev/null 2>&1; then
    return 0
  fi
  log "Namespace ${NS} not found on ${CTX_EAST}; deploying Bookinfo first..."
  CTX_EAST="$CTX_EAST" CTX_WEST="$CTX_WEST" BOOKINFO_NS="$NS" "${SCRIPT_DIR}/deploy-bookinfo.sh"
}

main() {
  log "=== Validate use cases (Istio ${ISTIO_VERSION}) ==="
  log "Contexts: east=${CTX_EAST}, west=${CTX_WEST}"
  log "Namespace: ${NS}"
  log ""

  ensure_bookinfo_present

  log "Running: traffic shifting (VirtualService via waypoint) ..."
  CTX_EAST="$CTX_EAST" NS="$NS" DEMO_MODE=fast "${SCRIPT_DIR}/demo-traffic-shift.sh"
  log ""

  log "Running: cross-cluster failover (reviews/ratings) ..."
  CTX_EAST="$CTX_EAST" CTX_WEST="$CTX_WEST" NS="$NS" DEMO_MODE=fast "${SCRIPT_DIR}/demo-failover.sh"
  log ""

  log "All validations completed successfully."
}

main "$@"

