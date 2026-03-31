#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="${CACHE_DIR:-${ROOT_DIR}/.cache}"
ISTIO_CACHE_DIR="${ISTIO_CACHE_DIR:-${CACHE_DIR}/istio}"

CTX_EAST="${CTX_EAST:-east2}"
CTX_WEST="${CTX_WEST:-west2}"
CTX_ACM="${CTX_ACM:-acm2}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.0}"
MESH_ID="${MESH_ID:-mesh1}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_context() {
  local ctx="$1"
  kubectl config get-contexts "$ctx" >/dev/null 2>&1 || die "kubeconfig context not found: ${ctx}"
}

os_arch() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  # Istio release artifacts use "osx" for macOS, not "darwin"
  [[ "$os" == "darwin" ]] && os="osx"
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
  esac
  echo "${os}-${arch}"
}

istio_minor() {
  echo "$ISTIO_VERSION" | awk -F. '{print $1"."$2}'
}

istioctl_path() {
  echo "${ISTIO_CACHE_DIR}/${ISTIO_VERSION}/istioctl"
}

download_istioctl() {
  need curl
  need tar

  local dst dir tgz url oa
  dst="$(istioctl_path)"
  if [[ -x "$dst" ]]; then
    log "istioctl already present: $dst"
    return 0
  fi

  oa="$(os_arch)"
  dir="$(dirname "$dst")"
  mkdir -p "$dir"

  # Istio release tarballs are: istio-<version>-<os>-<arch>.tar.gz
  tgz="${dir}/istio-${ISTIO_VERSION}-${oa}.tar.gz"
  url="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-${oa}.tar.gz"

  log "Downloading istioctl ${ISTIO_VERSION} (${oa})..."
  curl -fsSL "$url" -o "$tgz"
  tar -xzf "$tgz" -C "$dir"
  mv "${dir}/istio-${ISTIO_VERSION}/bin/istioctl" "$dst"
  chmod +x "$dst"
  rm -rf "${dir}/istio-${ISTIO_VERSION}" "$tgz"
  log "Installed istioctl: $dst"
}

istioctl() {
  "$(istioctl_path)" "$@"
}

apply_yaml() {
  local ctx="$1"
  local ns="$2"
  shift 2
  if [[ -n "$ns" ]]; then
    kubectl --context "$ctx" apply -n "$ns" -f - "$@"
  else
    kubectl --context "$ctx" apply -f - "$@"
  fi
}

wait_ready() {
  local ctx="$1" ns="$2" kind="$3" name="$4" timeout="${5:-180s}"
  kubectl --context "$ctx" -n "$ns" rollout status "${kind}/${name}" "--timeout=${timeout}"
}

bookinfo_waypoints_configured() {
  local ctx="$1" ns="$2"
  kubectl --context "$ctx" -n "$ns" get gateway.gateway.networking.k8s.io waypoint >/dev/null 2>&1 || return 1
  kubectl --context "$ctx" -n "$ns" get svc reviews -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null | grep -q '^waypoint$' || return 1
  return 0
}

enable_kiali_ambient_compat_rules() {
  local ctx="$1" ns="$2"
  # Kiali commonly expects reporter=source/destination. In Ambient with waypoints, telemetry may be emitted as reporter=waypoint.
  # This rule derives source/destination series from waypoint series for the bookinfo namespace.
  apply_yaml "$ctx" "$ns" <<EOF >/dev/null
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kiali-ambient-compat
  labels:
    openshift.io/user-monitoring: "true"
spec:
  groups:
  - name: kiali-ambient-compat
    interval: 30s
    rules:
    - record: istio_request_duration_milliseconds_bucket
      expr: label_replace(istio_request_duration_milliseconds_bucket{reporter="waypoint"},"reporter","source","reporter","waypoint")
    - record: istio_request_duration_milliseconds_bucket
      expr: label_replace(istio_request_duration_milliseconds_bucket{reporter="waypoint"},"reporter","destination","reporter","waypoint")
    - record: istio_requests_total
      expr: label_replace(istio_requests_total{reporter="waypoint"},"reporter","source","reporter","waypoint")
    - record: istio_requests_total
      expr: label_replace(istio_requests_total{reporter="waypoint"},"reporter","destination","reporter","waypoint")
    - record: istio_request_bytes
      expr: label_replace(istio_request_bytes{reporter="waypoint"},"reporter","source","reporter","waypoint")
    - record: istio_request_bytes
      expr: label_replace(istio_request_bytes{reporter="waypoint"},"reporter","destination","reporter","waypoint")
    - record: istio_response_bytes
      expr: label_replace(istio_response_bytes{reporter="waypoint"},"reporter","source","reporter","waypoint")
    - record: istio_response_bytes
      expr: label_replace(istio_response_bytes{reporter="waypoint"},"reporter","destination","reporter","waypoint")
    - record: istio_tcp_sent_bytes_total
      expr: label_replace(istio_tcp_sent_bytes_total{reporter="waypoint"},"reporter","source","reporter","waypoint")
    - record: istio_tcp_sent_bytes_total
      expr: label_replace(istio_tcp_sent_bytes_total{reporter="waypoint"},"reporter","destination","reporter","waypoint")
    - record: istio_tcp_received_bytes_total
      expr: label_replace(istio_tcp_received_bytes_total{reporter="waypoint"},"reporter","source","reporter","waypoint")
    - record: istio_tcp_received_bytes_total
      expr: label_replace(istio_tcp_received_bytes_total{reporter="waypoint"},"reporter","destination","reporter","waypoint")
EOF
}

enable_bookinfo_waypoints() {
  local ctx="$1" ns="$2"

  download_istioctl

  log "Enabling Bookinfo waypoints (temporary) on ${ctx}/${ns}..."

  # Use a single namespace waypoint (Istio docs pattern).
  # On OpenShift, service traffic may appear as "workload" at interception time (DNAT),
  # so we use --for all to ensure waypoint transit is enforced reliably.
  istioctl --context "$ctx" waypoint apply -n "$ns" --for all --name waypoint >/dev/null || true

  # Waypoint deployment runs with fixed UID (1337) and needs anyuid SCC on OpenShift.
  oc --context "$ctx" adm policy add-scc-to-user anyuid -n "$ns" -z waypoint >/dev/null 2>&1 || true

  # Enroll services to use the waypoint.
  for svc in productpage reviews ratings details; do
    kubectl --context "$ctx" -n "$ns" label svc "$svc" istio.io/use-waypoint=waypoint --overwrite >/dev/null
  done

  # Multicluster ambient requirement: mark waypoint service as global.
  kubectl --context "$ctx" -n "$ns" label svc waypoint istio.io/global=true --overwrite >/dev/null 2>&1 || true

  # Ensure waypoints are scraped for metrics (Kiali graph).
  apply_yaml "$ctx" "$ns" <<'EOF' >/dev/null
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istio-waypoints-monitor
  labels:
    k8s-app: waypoint-monitor
    openshift.io/user-monitoring: "true"
spec:
  selector:
    matchExpressions:
    - key: gateway.networking.k8s.io/gateway-name
      operator: Exists
  podMetricsEndpoints:
  - path: /stats/prometheus
    port: http-envoy-prom
    interval: 30s
EOF

  enable_kiali_ambient_compat_rules "$ctx" "$ns"

  kubectl --context "$ctx" -n "$ns" rollout status deploy/waypoint --timeout=180s >/dev/null

  log "Waypoints enabled on ${ctx}/${ns}."
}

disable_bookinfo_waypoints() {
  local ctx="$1" ns="$2"

  log "Disabling Bookinfo waypoints (cleanup) on ${ctx}/${ns}..."

  kubectl --context "$ctx" -n "$ns" delete prometheusrule kiali-ambient-compat --ignore-not-found >/dev/null 2>&1 || true
  # Note: baseline installations may already include the PodMonitor; keep it in place.

  for svc in productpage reviews ratings details; do
    kubectl --context "$ctx" -n "$ns" label svc "$svc" istio.io/use-waypoint- istio.io/use-waypoint-namespace- >/dev/null 2>&1 || true
  done

  kubectl --context "$ctx" -n "$ns" delete gateway.gateway.networking.k8s.io waypoint --ignore-not-found >/dev/null 2>&1 || true
  oc --context "$ctx" -n "$ns" delete deploy waypoint --ignore-not-found >/dev/null 2>&1 || true
  oc --context "$ctx" -n "$ns" delete svc waypoint --ignore-not-found >/dev/null 2>&1 || true

  # Best-effort SCC cleanup (waypoint SA only).
  oc --context "$ctx" adm policy remove-scc-from-user anyuid -n "$ns" -z waypoint >/dev/null 2>&1 || true

  log "Waypoints disabled on ${ctx}/${ns}."
}

