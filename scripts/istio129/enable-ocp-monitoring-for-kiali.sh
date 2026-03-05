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

label_monitoring_namespaces() {
  local ctx="$1"
  log "Enabling OpenShift monitoring collection for namespaces on ${ctx}..."
  oc --context "$ctx" label ns "$ISTIO_NS" openshift.io/cluster-monitoring=true --overwrite >/dev/null
  oc --context "$ctx" label ns "$NS" openshift.io/cluster-monitoring=true --overwrite >/dev/null
}

ensure_envoy_metrics_port_on_service() {
  local ctx="$1" svc="$2"

  if kubectl --context "$ctx" -n "$NS" get svc "$svc" -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' 2>/dev/null | grep -qx '15090'; then
    return 0
  fi

  log "Patching ${ctx}/${NS} service ${svc} to expose 15090 (/stats/prometheus)..."
  kubectl --context "$ctx" -n "$NS" patch svc "$svc" --type='json' -p='[
    {"op":"add","path":"/spec/ports/-","value":{"name":"http-envoy-prom","port":15090,"protocol":"TCP","targetPort":15090}}
  ]' >/dev/null
}

label_metrics_services() {
  local ctx="$1"
  log "Labeling services for ServiceMonitor selection on ${ctx}..."
  for svc in bookinfo-gateway-istio productpage-waypoint reviews-waypoint ratings-waypoint details-waypoint; do
    kubectl --context "$ctx" -n "$NS" label svc "$svc" istio-metrics=envoy --overwrite >/dev/null 2>&1 || true
  done
}

apply_servicemonitor() {
  local ctx="$1"
  log "Applying ServiceMonitor in ${ctx}/${NS}..."
  kubectl --context "$ctx" apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istio-envoy-metrics
  labels:
    monitoring.openshift.io/collection-profile: full
spec:
  selector:
    matchLabels:
      istio-metrics: envoy
  endpoints:
    - port: http-envoy-prom
      path: /stats/prometheus
      interval: 15s
      scheme: http
EOF
}

main() {
  log "=== Enable OpenShift monitoring for Kiali traffic graphs ==="
  log "Contexts: east=${CTX_EAST}, west=${CTX_WEST}"
  log "Namespaces: istio=${ISTIO_NS}, app=${NS}"
  log ""

  for ctx in "$CTX_EAST" "$CTX_WEST"; do
    label_monitoring_namespaces "$ctx"

    for svc in bookinfo-gateway-istio productpage-waypoint reviews-waypoint ratings-waypoint details-waypoint; do
      ensure_envoy_metrics_port_on_service "$ctx" "$svc"
    done

    label_metrics_services "$ctx"
    apply_servicemonitor "$ctx"
  done

  log ""
  log "Done. It can take ~1-3 minutes for metrics to appear in Thanos/Promxy."
  log "Tip: generate traffic with demo scripts, then query promxy for istio_requests_total."
}

main "$@"

