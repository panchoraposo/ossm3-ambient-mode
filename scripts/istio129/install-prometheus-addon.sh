#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
need oc
need curl

require_context "$CTX_EAST"
require_context "$CTX_WEST"

PROM_NS="${PROM_NS:-istio-system}"

istio_release_branch() {
  # ISTIO_VERSION=1.29.0 -> release-1.29
  echo "release-$(echo "$ISTIO_VERSION" | awk -F. '{print $1 "." $2}')"
}

resolve_host_ip() {
  local host="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$host" 2>/dev/null
}

apply_prometheus_addon() {
  local ctx="$1"
  local branch url
  branch="$(istio_release_branch)"
  url="https://raw.githubusercontent.com/istio/istio/${branch}/samples/addons/prometheus.yaml"
  log "Installing Prometheus addon on ${ctx} (${PROM_NS}) from ${branch}..."
  kubectl --context "$ctx" apply -n "$PROM_NS" -f "$url" >/dev/null
}

expose_prometheus_loadbalancer() {
  local ctx="$1"
  log "Patching ${PROM_NS}/prometheus Service to type LoadBalancer on ${ctx}..."
  kubectl --context "$ctx" -n "$PROM_NS" patch svc prometheus --type merge -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null

  log "Waiting for Prometheus LoadBalancer address on ${ctx}..."
  local host ip
  for _ in {1..180}; do
    host="$(kubectl --context "$ctx" -n "$PROM_NS" get svc prometheus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    ip="$(kubectl --context "$ctx" -n "$PROM_NS" get svc prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${host:-}" || -n "${ip:-}" ]] && break
    sleep 2
  done
  [[ -n "${host:-}" || -n "${ip:-}" ]] || die "Timed out waiting for Prometheus LoadBalancer address on ${ctx}"

  if [[ -n "${ip:-}" ]]; then
    log "Prometheus LB on ${ctx}: ${ip}:9090"
  else
    local rip
    rip="$(resolve_host_ip "$host" || true)"
    log "Prometheus LB on ${ctx}: ${host}:9090${rip:+ (ip=${rip})}"
  fi
}

expose_prometheus_route() {
  local ctx="$1"
  log "Creating OpenShift Route ${PROM_NS}/prometheus on ${ctx}..."
  kubectl --context "$ctx" apply -n "$PROM_NS" -f - >/dev/null <<'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: prometheus
spec:
  to:
    kind: Service
    name: prometheus
  port:
    targetPort: 9090
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
}

wait_prometheus_ready() {
  local ctx="$1"
  log "Waiting for Prometheus deployment on ${ctx}..."
  kubectl --context "$ctx" -n "$PROM_NS" rollout status deploy/prometheus --timeout=180s >/dev/null
}

patch_recording_rules_for_kiali_graph() {
  local ctx="$1"
  # Kiali Graph (especially older UI variants) often queries istio_requests_total with reporter=source|destination.
  # In Ambient mode with waypoints, HTTP telemetry is commonly reported with reporter=waypoint.
  # These recording rules duplicate waypoint telemetry into source/destination series so the Graph is not empty.
  log "Patching Prometheus recording rules on ${ctx} for Kiali Ambient graphs..."
  kubectl --context "$ctx" -n "$PROM_NS" patch cm prometheus --type merge -p "$(cat <<'EOF'
{
  "data": {
    "recording_rules.yml": "groups:\n- name: kiali-ambient-compat\n  interval: 30s\n  rules:\n  - record: istio_requests_total\n    expr: label_replace(istio_requests_total{reporter=\"waypoint\"}, \"reporter\", \"source\", \"reporter\", \"waypoint\")\n  - record: istio_requests_total\n    expr: label_replace(istio_requests_total{reporter=\"waypoint\"}, \"reporter\", \"destination\", \"reporter\", \"waypoint\")\n"
  }
}
EOF
)" >/dev/null
}

restart_prometheus() {
  local ctx="$1"
  log "Restarting Prometheus on ${ctx}..."
  kubectl --context "$ctx" -n "$PROM_NS" rollout restart deploy/prometheus >/dev/null
  kubectl --context "$ctx" -n "$PROM_NS" rollout status deploy/prometheus --timeout=180s >/dev/null
}

main() {
  log "=== Install Prometheus addon (Istio ${ISTIO_VERSION}) ==="
  log "Contexts: east=${CTX_EAST}, west=${CTX_WEST}"
  log "Namespace: ${PROM_NS}"
  log ""

  for ctx in "$CTX_EAST" "$CTX_WEST"; do
    apply_prometheus_addon "$ctx"
    expose_prometheus_loadbalancer "$ctx"
    expose_prometheus_route "$ctx"
    wait_prometheus_ready "$ctx"
    patch_recording_rules_for_kiali_graph "$ctx"
    restart_prometheus "$ctx"
    log "Prometheus Route on ${ctx}: $(oc --context "$ctx" -n "$PROM_NS" get route prometheus -o jsonpath='{.spec.host}')"
  done
}

main "$@"

