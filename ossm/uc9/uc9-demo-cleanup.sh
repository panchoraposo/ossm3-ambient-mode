#!/bin/bash
#
# UC9 Demo Cleanup Helper
#
# Deletes ONLY the UC9 demo namespaces/resources created by `uc9-verify.sh` when running with KIALI_DEMO=true.
# Safe: does NOT touch `bookinfo`.
#
# Usage:
#   bash ossm/uc9/uc9-demo-cleanup.sh [context]
# Example:
#   bash ossm/uc9/uc9-demo-cleanup.sh east
#

set -euo pipefail

CTX="${1:-east}"

CLIENT_NS="${CLIENT_NS:-uc9-client}"
EGRESS_NS="${EGRESS_NS:-egress-custom-cert}"
BACKEND_NS="${BACKEND_NS:-custom-cert-backend}"
CLIENT_WAYPOINT_NAME="${CLIENT_WAYPOINT_NAME:-uc9-client}"

WAIT_CLEANUP="${WAIT_CLEANUP:-true}"
CLEANUP_TIMEOUT_SEC="${CLEANUP_TIMEOUT_SEC:-300}"
WAIT_POLL_SEC="${WAIT_POLL_SEC:-2}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

wait_ns_deleted() {
  local ns="$1"
  local deadline=$(( $(date +%s) + CLEANUP_TIMEOUT_SEC ))
  while oc --context "$CTX" get ns "$ns" >/dev/null 2>&1; do
    if [[ $(date +%s) -ge $deadline ]]; then
      echo "WARN: namespace ${ns} still exists after ${CLEANUP_TIMEOUT_SEC}s" >&2
      return 0
    fi
    sleep "${WAIT_POLL_SEC}"
  done
}

need_cmd oc
need_cmd istioctl

echo "Cleaning UC9 demo resources on context: ${CTX}"
echo "Namespaces: ${CLIENT_NS} ${EGRESS_NS} ${BACKEND_NS}"

# Best-effort deletes (namespaces remove everything inside).
istioctl --context "$CTX" waypoint delete --namespace "$CLIENT_NS" "$CLIENT_WAYPOINT_NAME" >/dev/null 2>&1 || true
oc --context "$CTX" delete ns "$CLIENT_NS" "$EGRESS_NS" "$BACKEND_NS" --wait=false >/dev/null 2>&1 || true

if [[ "${WAIT_CLEANUP}" == "true" ]]; then
  echo "Waiting for namespaces to be deleted..."
  wait_ns_deleted "$CLIENT_NS"
  wait_ns_deleted "$EGRESS_NS"
  wait_ns_deleted "$BACKEND_NS"
fi

echo "Done."

