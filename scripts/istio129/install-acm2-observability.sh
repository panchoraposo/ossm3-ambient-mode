#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
need oc

require_context "$CTX_ACM"
require_context "$CTX_EAST"
require_context "$CTX_WEST"

ISTIO_NS="${ISTIO_NS:-istio-system}"
KIALI_OPERATOR_NS="${KIALI_OPERATOR_NS:-kiali-operator}"
PROMXY_SVC_NAME="${PROMXY_SVC_NAME:-promxy}"
PROMXY_PORT="${PROMXY_PORT:-9090}"

REMOTE_SA_NS="${REMOTE_SA_NS:-istio-system}"
REMOTE_SA_NAME="${REMOTE_SA_NAME:-kiali-remote-reader}"
KIALI_REMOTE_CLUSTER_ADMIN="${KIALI_REMOTE_CLUSTER_ADMIN:-true}"

PROM_BACKEND_NS="${PROM_BACKEND_NS:-openshift-monitoring}"
PROM_BACKEND_SVC="${PROM_BACKEND_SVC:-thanos-querier}"
PROM_BACKEND_SVC_PORT="${PROM_BACKEND_SVC_PORT:-9091}"
PROM_BACKEND_SVC_SCHEME="${PROM_BACKEND_SVC_SCHEME:-https}"

PROMXY_IMAGE="${PROMXY_IMAGE:-quay.io/jacksontj/promxy:v0.0.93}"

TRACING_ENABLED="${TRACING_ENABLED:-true}"
TRACING_USE_WAYPOINT_NAME="${TRACING_USE_WAYPOINT_NAME:-true}"
TEMPO_NS="${TEMPO_NS:-${ISTIO_NS}}"
TEMPO_SVC_NAME="${TEMPO_SVC_NAME:-tempo}"
TEMPO_QUERY_PORT="${TEMPO_QUERY_PORT:-3200}"
TEMPO_INTERNAL_URL="${TEMPO_INTERNAL_URL:-http://${TEMPO_SVC_NAME}.${TEMPO_NS}.svc.cluster.local:${TEMPO_QUERY_PORT}/}"

log "=== Hub observability on ${CTX_ACM} (Kiali multi-cluster + promxy) ==="
log "Hub: ${CTX_ACM}"
log "Remote clusters: ${CTX_EAST}, ${CTX_WEST}"
log ""

ensure_ns() {
  local ctx="$1" ns="$2"
  kubectl --context "$ctx" get ns "$ns" >/dev/null 2>&1 || kubectl --context "$ctx" create ns "$ns" >/dev/null
}

base64_file() {
  local p="$1"
  if base64 --help 2>/dev/null | grep -q -- "-w"; then
    base64 -w 0 "$p"
  else
    base64 "$p" | tr -d '\n'
  fi
}

resolve_host_ip() {
  local host="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$host" 2>/dev/null
}

ctx_cluster_server() {
  local ctx="$1"
  kubectl --context "$ctx" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}'
}

server_url_to_hostport() {
  local url="$1"
  url="${url#https://}"
  url="${url#http://}"
  url="${url%/}"
  printf '%s' "$url"
}

ctx_cluster_ca_data() {
  local ctx="$1"
  local ca_data ca_file
  ca_data="$(kubectl --context "$ctx" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
  if [[ -n "${ca_data:-}" ]]; then
    printf '%s' "$ca_data"
    return 0
  fi
  ca_file="$(kubectl --context "$ctx" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)"
  if [[ -n "${ca_file:-}" && -f "${ca_file}" ]]; then
    base64_file "$ca_file"
    return 0
  fi
  # Some kubeconfigs (or auth plugins) don't provide CA material locally. In that case,
  # we fall back to insecure-skip-tls-verify in the generated kubeconfigs (demo mode).
  printf ''
}

ensure_remote_sa_and_token() {
  local ctx="$1"

  ensure_ns "$ctx" "$REMOTE_SA_NS"

  kubectl --context "$ctx" -n "$REMOTE_SA_NS" get sa "$REMOTE_SA_NAME" >/dev/null 2>&1 \
    || kubectl --context "$ctx" -n "$REMOTE_SA_NS" create sa "$REMOTE_SA_NAME" >/dev/null

  # Kiali needs broad read access; promxy needs to proxy to monitoring services.
  # For demo purposes, grant cluster-reader + cluster-monitoring-view.
  oc --context "$ctx" adm policy add-cluster-role-to-user cluster-reader -z "$REMOTE_SA_NAME" -n "$REMOTE_SA_NS" >/dev/null 2>&1 || true
  oc --context "$ctx" adm policy add-cluster-role-to-user cluster-monitoring-view -z "$REMOTE_SA_NAME" -n "$REMOTE_SA_NS" >/dev/null 2>&1 || true
  if [[ "${KIALI_REMOTE_CLUSTER_ADMIN}" == "true" ]]; then
    # Kiali may need port-forward and access to some Istio CRDs not covered by cluster-reader in some OpenShift setups.
    oc --context "$ctx" adm policy add-cluster-role-to-user cluster-admin -z "$REMOTE_SA_NAME" -n "$REMOTE_SA_NS" >/dev/null 2>&1 || true
  fi

  # Make sure namespaces where Istio emits metrics are scraped by OpenShift UWM.
  # (Best-effort; harmless if UWM isn't enabled.)
  for ns in istio-system bookinfo; do
    kubectl --context "$ctx" label ns "$ns" openshift.io/user-monitoring=true --overwrite >/dev/null 2>&1 || true
  done

  # Long-lived token for promxy/Kiali to use to reach the remote API server.
  # (OpenShift supports 'oc create token' / 'kubectl create token'.)
  oc --context "$ctx" -n "$REMOTE_SA_NS" create token "$REMOTE_SA_NAME" --duration=8760h
}

make_kubeconfig_yaml() {
  local name="$1" server="$2" ca_data="$3" token="$4"
  local cluster_tls
  if [[ -n "${ca_data:-}" ]]; then
    cluster_tls="certificate-authority-data: ${ca_data}"
  else
    cluster_tls="insecure-skip-tls-verify: true"
  fi
  cat <<EOF
apiVersion: v1
kind: Config
preferences: {}
current-context: ${name}
clusters:
- name: ${name}
  cluster:
    server: ${server}
    ${cluster_tls}
contexts:
- name: ${name}
  context:
    cluster: ${name}
    user: ${name}
users:
- name: ${name}
  user:
    token: ${token}
EOF
}

apply_kiali_multicluster_secret() {
  local east_kc="$1" west_kc="$2"
  ensure_ns "$CTX_ACM" "$ISTIO_NS"
  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kiali-multi-cluster-secret
  namespace: ${ISTIO_NS}
  labels:
    kiali.io/multiCluster: "true"
    kiali.io/kiali-multi-cluster-secret: "true"
type: Opaque
stringData:
  ${CTX_EAST}: |
$(printf '%s\n' "$east_kc" | sed 's/^/    /')
  ${CTX_WEST}: |
$(printf '%s\n' "$west_kc" | sed 's/^/    /')
EOF
}

install_kiali_operator_on_hub() {
  log "Installing Kiali Operator on ${CTX_ACM}..."
  ensure_ns "$CTX_ACM" "$KIALI_OPERATOR_NS"

  kubectl --context "$CTX_ACM" -n "$KIALI_OPERATOR_NS" apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kiali-operator-group
  namespace: ${KIALI_OPERATOR_NS}
spec: {}
EOF

  kubectl --context "$CTX_ACM" -n "$KIALI_OPERATOR_NS" apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kiali-ossm
  namespace: ${KIALI_OPERATOR_NS}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kiali-ossm
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  for _ in {1..90}; do
    oc --context "$CTX_ACM" -n "$KIALI_OPERATOR_NS" get deploy kiali-operator >/dev/null 2>&1 && break
    sleep 5
  done
  oc --context "$CTX_ACM" -n "$KIALI_OPERATOR_NS" rollout status deploy/kiali-operator --timeout=300s >/dev/null

  for _ in {1..90}; do
    oc --context "$CTX_ACM" get crd kialis.kiali.io >/dev/null 2>&1 && break
    sleep 5
  done
}

deploy_promxy_on_hub() {
  log "Deploying promxy on ${CTX_ACM}..."
  ensure_ns "$CTX_ACM" "$ISTIO_NS"

  local east_target west_target path_prefix
  path_prefix=""
  if [[ "$PROM_BACKEND_NS" == "istio-system" && "$PROM_BACKEND_SVC" == "prometheus" ]]; then
    # Prefer querying remote Prometheus via the remote Kubernetes API server proxy:
    # avoids relying on Routes/LBs being reachable from the hub cluster.
    local east_server west_server
    east_server="$(ctx_cluster_server "$CTX_EAST")"
    west_server="$(ctx_cluster_server "$CTX_WEST")"
    east_target="$(server_url_to_hostport "$east_server")"
    west_target="$(server_url_to_hostport "$west_server")"
    PROM_BACKEND_SVC_SCHEME="https"
    path_prefix="/api/v1/namespaces/${PROM_BACKEND_NS}/services/${PROM_BACKEND_SVC}:9090/proxy"
  else
    # Default: use each cluster's backend Route (Thanos, etc).
    east_target="$(oc --context "$CTX_EAST" -n "$PROM_BACKEND_NS" get route "$PROM_BACKEND_SVC" -o jsonpath='{.spec.host}'):443"
    west_target="$(oc --context "$CTX_WEST" -n "$PROM_BACKEND_NS" get route "$PROM_BACKEND_SVC" -o jsonpath='{.spec.host}'):443"
  fi

  local east_token west_token
  east_token="$(ensure_remote_sa_and_token "$CTX_EAST")"
  west_token="$(ensure_remote_sa_and_token "$CTX_WEST")"

  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: promxy-upstreams
  namespace: ${ISTIO_NS}
type: Opaque
stringData:
  EAST_TARGET: ${east_target}
  WEST_TARGET: ${west_target}
  EAST_TOKEN: ${east_token}
  WEST_TOKEN: ${west_token}
  BACKEND_SCHEME: ${PROM_BACKEND_SVC_SCHEME}
  PATH_PREFIX: ${path_prefix}
EOF

  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: promxy-config-template
data:
  config.yaml.tmpl: |
    global:
      evaluation_interval: 30s
      external_labels:
        source: promxy-hub
    promxy:
      server_groups:
      - static_configs:
        - targets: ["__EAST_TARGET__"]
        labels:
          cluster: east2
        anti_affinity: 30s
        ignore_error: true
        scheme: __BACKEND_SCHEME__
        path_prefix: "__PATH_PREFIX__"
        http_client:
          bearer_token: "__EAST_TOKEN__"
          tls_config:
            insecure_skip_verify: true
      - static_configs:
        - targets: ["__WEST_TARGET__"]
        labels:
          cluster: west2
        anti_affinity: 30s
        ignore_error: true
        scheme: __BACKEND_SCHEME__
        path_prefix: "__PATH_PREFIX__"
        http_client:
          bearer_token: "__WEST_TOKEN__"
          tls_config:
            insecure_skip_verify: true
EOF

  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROMXY_SVC_NAME}
  namespace: ${ISTIO_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROMXY_SVC_NAME}
  template:
    metadata:
      labels:
        app: ${PROMXY_SVC_NAME}
    spec:
      serviceAccountName: default
      volumes:
        - name: config-out
          emptyDir: {}
        - name: cfg-tpl
          configMap:
            name: promxy-config-template
        - name: upstreams
          secret:
            secretName: promxy-upstreams
      initContainers:
        - name: render-config
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["sh","-c"]
          args:
            - |
              set -euo pipefail
              TPL="/tpl/config.yaml.tmpl"
              OUT="/config/config.yaml"
              EAST_TARGET="\$(cat /upstreams/EAST_TARGET)"
              WEST_TARGET="\$(cat /upstreams/WEST_TARGET)"
              EAST_TOKEN="\$(cat /upstreams/EAST_TOKEN)"
              WEST_TOKEN="\$(cat /upstreams/WEST_TOKEN)"
              BACKEND_SCHEME="\$(cat /upstreams/BACKEND_SCHEME 2>/dev/null || echo https)"
              PATH_PREFIX="\$(cat /upstreams/PATH_PREFIX 2>/dev/null || echo '')"
              sed \
                -e "s|__EAST_TARGET__|\${EAST_TARGET}|g" \
                -e "s|__WEST_TARGET__|\${WEST_TARGET}|g" \
                -e "s|__EAST_TOKEN__|\${EAST_TOKEN}|g" \
                -e "s|__WEST_TOKEN__|\${WEST_TOKEN}|g" \
                -e "s|__BACKEND_SCHEME__|\${BACKEND_SCHEME}|g" \
                -e "s|__PATH_PREFIX__|\${PATH_PREFIX}|g" \
                "\$TPL" > "\$OUT"
          volumeMounts:
            - name: cfg-tpl
              mountPath: /tpl
            - name: upstreams
              mountPath: /upstreams
              readOnly: true
            - name: config-out
              mountPath: /config
      containers:
        - name: promxy
          image: ${PROMXY_IMAGE}
          args: ["--config=/config/config.yaml","--bind-addr=:${PROMXY_PORT}"]
          ports:
            - name: http
              containerPort: ${PROMXY_PORT}
          readinessProbe:
            httpGet:
              path: /-/ready
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: http
            periodSeconds: 20
            timeoutSeconds: 2
          volumeMounts:
            - name: config-out
              mountPath: /config
EOF

  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PROMXY_SVC_NAME}
  namespace: ${ISTIO_NS}
spec:
  selector:
    app: ${PROMXY_SVC_NAME}
  ports:
    - name: http
      port: ${PROMXY_PORT}
      targetPort: http
EOF

  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${PROMXY_SVC_NAME}
  namespace: ${ISTIO_NS}
spec:
  to:
    kind: Service
    name: ${PROMXY_SVC_NAME}
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

  oc --context "$CTX_ACM" -n "$ISTIO_NS" rollout status deploy/${PROMXY_SVC_NAME} --timeout=300s >/dev/null
  local promxy_host
  promxy_host="$(oc --context "$CTX_ACM" -n "$ISTIO_NS" get route ${PROMXY_SVC_NAME} -o jsonpath='{.spec.host}')"
  log "promxy route: https://${promxy_host}"
}

deploy_kiali_on_hub() {
  log "Deploying central Kiali on ${CTX_ACM}..."
  ensure_ns "$CTX_ACM" "$ISTIO_NS"

  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<EOF
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: ${ISTIO_NS}
spec:
  auth:
    strategy: anonymous
  clustering:
    ignore_home_cluster: true
    autodetect_secrets:
      enabled: true
      label: kiali.io/multiCluster=true
  deployment:
    accessible_namespaces: ["**"]
    cluster_wide_access: true
    instance_name: kiali
  external_services:
    prometheus:
      url: "http://${PROMXY_SVC_NAME}.${ISTIO_NS}.svc.cluster.local:${PROMXY_PORT}"
      is_core: true
      auth:
        type: none
    tracing:
      enabled: ${TRACING_ENABLED}
      provider: tempo
      internal_url: "${TEMPO_INTERNAL_URL}"
      use_grpc: false
      use_waypoint_name: ${TRACING_USE_WAYPOINT_NAME}
      auth:
        type: none
    grafana:
      enabled: false
  kubernetes_config:
    cluster_name: ${CTX_ACM}
EOF

  # Expose Kiali via OpenShift Route (service is created by the operator)
  for _ in {1..60}; do
    kubectl --context "$CTX_ACM" -n "$ISTIO_NS" get svc kiali >/dev/null 2>&1 && break
    sleep 5
  done

  # Kiali serves HTTPS on 20001 (service serving cert). Use reencrypt so the router
  # terminates public TLS and re-encrypts to the backend.
  local svc_ca
  svc_ca="$(oc --context "$CTX_ACM" -n "$ISTIO_NS" get configmap openshift-service-ca.crt -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)"
  [[ -n "${svc_ca:-}" ]] || die "Could not read service CA bundle from ${ISTIO_NS}/openshift-service-ca.crt on ${CTX_ACM}"

  kubectl --context "$CTX_ACM" -n "$ISTIO_NS" apply -f - >/dev/null <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: kiali
  namespace: ${ISTIO_NS}
spec:
  to:
    kind: Service
    name: kiali
  port:
    targetPort: 20001
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    destinationCACertificate: |
$(printf '%s\n' "$svc_ca" | sed 's/^/      /')
EOF

  local kiali_host
  kiali_host="$(oc --context "$CTX_ACM" -n "$ISTIO_NS" get route kiali -o jsonpath='{.spec.host}')"
  log "Kiali route: https://${kiali_host}"
}

main() {
  # Build kubeconfigs for Kiali multi-cluster secret
  log "Preparing remote access tokens (east2/west2)..."
  local east_server west_server east_ca west_ca east_token west_token
  east_server="$(ctx_cluster_server "$CTX_EAST")"
  west_server="$(ctx_cluster_server "$CTX_WEST")"
  east_ca="$(ctx_cluster_ca_data "$CTX_EAST")"
  west_ca="$(ctx_cluster_ca_data "$CTX_WEST")"
  east_token="$(ensure_remote_sa_and_token "$CTX_EAST")"
  west_token="$(ensure_remote_sa_and_token "$CTX_WEST")"

  log "Creating Kiali multi-cluster secret on ${CTX_ACM}/${ISTIO_NS}..."
  local east_kc west_kc
  east_kc="$(make_kubeconfig_yaml "$CTX_EAST" "$east_server" "$east_ca" "$east_token")"
  west_kc="$(make_kubeconfig_yaml "$CTX_WEST" "$west_server" "$west_ca" "$west_token")"
  apply_kiali_multicluster_secret "$east_kc" "$west_kc"

  install_kiali_operator_on_hub
  deploy_promxy_on_hub
  deploy_kiali_on_hub

  log ""
  log "Hub observability installed."
  log "Next: run the demos:"
  log "  CTX_EAST=${CTX_EAST} ./scripts/istio129/demo-traffic-shift.sh"
  log "  CTX_EAST=${CTX_EAST} CTX_WEST=${CTX_WEST} ./scripts/istio129/demo-failover.sh"
}

main "$@"

