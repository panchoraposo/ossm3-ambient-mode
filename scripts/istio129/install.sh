#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
need oc
need openssl
need curl
need python3

require_context "$CTX_EAST"
require_context "$CTX_WEST"

download_istioctl

ISTIOCTL_BIN="$(istioctl_path)"
log "Using istioctl: ${ISTIOCTL_BIN}"
istioctl version || true

CERT_DIR="${CERT_DIR:-${ISTIO_CACHE_DIR}/certs/${MESH_ID}}"

prepare_openshift_prereqs() {
  local ctx="$1"
  kubectl --context "$ctx" get ns "$ISTIO_NS" >/dev/null 2>&1 || kubectl --context "$ctx" create ns "$ISTIO_NS" >/dev/null

  # Ensure service accounts exist early (avoids races during install)
  for sa in istiod istio-cni ztunnel; do
    kubectl --context "$ctx" -n "$ISTIO_NS" get sa "$sa" >/dev/null 2>&1 || kubectl --context "$ctx" -n "$ISTIO_NS" create sa "$sa" >/dev/null
  done

  # OpenShift SCC: Istio CNI and ztunnel need privileged (hostPath, NET_ADMIN, runAsUser 0).
  oc --context "$ctx" adm policy add-scc-to-user privileged -n "$ISTIO_NS" -z istio-cni >/dev/null 2>&1 || true
  oc --context "$ctx" adm policy add-scc-to-user privileged -n "$ISTIO_NS" -z ztunnel >/dev/null 2>&1 || true
}

is_ca_cert() {
  local pem="$1"
  openssl x509 -in "$pem" -noout -text 2>/dev/null | grep -q "CA:TRUE"
}

generate_cacerts() {
  mkdir -p "$CERT_DIR"
  if [[ -f "${CERT_DIR}/root-cert.pem" && -f "${CERT_DIR}/ca-cert.pem" && -f "${CERT_DIR}/ca-key.pem" && -f "${CERT_DIR}/cert-chain.pem" ]]; then
    if is_ca_cert "${CERT_DIR}/root-cert.pem" && is_ca_cert "${CERT_DIR}/ca-cert.pem"; then
      log "cacerts already present (valid CA certs): ${CERT_DIR}"
      return 0
    fi
    log "Existing cacerts look invalid (CA:TRUE missing). Regenerating..."
    rm -f "${CERT_DIR}/root-key.pem" "${CERT_DIR}/root-cert.pem" "${CERT_DIR}/ca-key.pem" "${CERT_DIR}/ca-cert.pem" "${CERT_DIR}/cert-chain.pem" "${CERT_DIR}/ca.csr" "${CERT_DIR}"/*.srl 2>/dev/null || true
  fi

  log "Generating shared cacerts into ${CERT_DIR} ..."
  # Root CA (CA:TRUE)
  openssl genrsa -out "${CERT_DIR}/root-key.pem" 4096 >/dev/null 2>&1
  cat >"${CERT_DIR}/root-openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[ dn ]
O = Istio Demo Root
CN = Istio Demo Root

[ v3_ca ]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
  openssl req -x509 -new -nodes -key "${CERT_DIR}/root-key.pem" -sha256 -days 3650 \
    -config "${CERT_DIR}/root-openssl.cnf" \
    -out "${CERT_DIR}/root-cert.pem" >/dev/null 2>&1

  # Intermediate CA (CA:TRUE)
  openssl genrsa -out "${CERT_DIR}/ca-key.pem" 4096 >/dev/null 2>&1
  openssl req -new -key "${CERT_DIR}/ca-key.pem" \
    -subj "/O=Istio Demo Intermediate/CN=Istio Demo Intermediate" \
    -out "${CERT_DIR}/ca.csr" >/dev/null 2>&1
  cat >"${CERT_DIR}/ca-ext.cnf" <<'EOF'
[ v3_ca ]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  openssl x509 -req -in "${CERT_DIR}/ca.csr" -CA "${CERT_DIR}/root-cert.pem" -CAkey "${CERT_DIR}/root-key.pem" \
    -CAcreateserial -out "${CERT_DIR}/ca-cert.pem" -days 3650 -sha256 \
    -extfile "${CERT_DIR}/ca-ext.cnf" -extensions v3_ca >/dev/null 2>&1

  cat "${CERT_DIR}/ca-cert.pem" "${CERT_DIR}/root-cert.pem" > "${CERT_DIR}/cert-chain.pem"

  rm -f "${CERT_DIR}/ca.csr" "${CERT_DIR}/root-openssl.cnf" "${CERT_DIR}/ca-ext.cnf" "${CERT_DIR}"/*.srl 2>/dev/null || true
}

apply_cacerts_secret() {
  local ctx="$1"
  kubectl --context "$ctx" get ns "$ISTIO_NS" >/dev/null 2>&1 || kubectl --context "$ctx" create ns "$ISTIO_NS" >/dev/null
  log "Applying cacerts to ${ctx}/${ISTIO_NS}..."
  kubectl --context "$ctx" -n "$ISTIO_NS" create secret generic cacerts \
    --from-file=ca-cert.pem="${CERT_DIR}/ca-cert.pem" \
    --from-file=ca-key.pem="${CERT_DIR}/ca-key.pem" \
    --from-file=root-cert.pem="${CERT_DIR}/root-cert.pem" \
    --from-file=cert-chain.pem="${CERT_DIR}/cert-chain.pem" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
}

ensure_gateway_api_crds() {
  # OpenShift clusters often include Gateway API CRDs, but ensure they exist.
  if kubectl --context "$CTX_EAST" get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    log "Gateway API CRDs already present."
    return 0
  fi
  need curl
  log "Installing Gateway API CRDs (standard-install.yaml)..."
  curl -fsSL "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml" \
    | kubectl --context "$CTX_EAST" apply -f - >/dev/null
  curl -fsSL "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml" \
    | kubectl --context "$CTX_WEST" apply -f - >/dev/null
}

openshift_patch_ambient_daemonsets() {
  # OpenShift SELinux can block hostPath UDS operations unless pods run with spc_t.
  # We patch DaemonSets opportunistically (only when they exist).
  local ctx="$1"
  for ds in istio-cni-node ztunnel; do
    kubectl --context "$ctx" -n "$ISTIO_NS" get ds "$ds" >/dev/null 2>&1 || continue
    kubectl --context "$ctx" -n "$ISTIO_NS" patch ds "$ds" --type='merge' \
      -p '{"spec":{"template":{"spec":{"securityContext":{"seLinuxOptions":{"type":"spc_t"}}}}}}' >/dev/null 2>&1 || true
  done
}

resolve_host_ip() {
  local host="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$host" 2>/dev/null
}

istioctl_install_with_openshift_patches() {
  local ctx="$1"
  local op_yaml="$2"

  # Run install in background, while applying OpenShift-specific patches
  # as soon as resources appear (prevents readiness-timeout loops).
  (
    printf '%s\n' "$op_yaml" | istioctl install --context "$ctx" -y -f - >/dev/null
  ) &
  local pid="$!"

  while kill -0 "$pid" >/dev/null 2>&1; do
    openshift_patch_ambient_daemonsets "$ctx"
    sleep 2
  done

  wait "$pid"
}

install_istio_base() {
  local ctx="$1" cluster_name="$2" network="$3"
  log "Installing Istio ${ISTIO_VERSION} (ambient) on ${ctx} (clusterName=${cluster_name}, network=${network})..."
  local op_yaml
  op_yaml="$(cat <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
  hub: docker.io/istio
  tag: ${ISTIO_VERSION}
  components:
    pilot:
      k8s:
        env:
          - name: AMBIENT_ENABLE_MULTI_NETWORK
            value: "true"
          - name: AMBIENT_ENABLE_BAGGAGE
            value: "true"
  meshConfig:
    accessLogFile: /dev/stdout
    enableTracing: true
    defaultConfig:
      tracing:
        sampling: 100.0
        zipkin:
          address: otel-collector.${ISTIO_NS}.svc.cluster.local:9411
  values:
    cni:
      # OpenShift uses /var/lib/cni/bin for CNI binaries (not /opt/cni/bin)
      cniBinDir: /var/lib/cni/bin
      cniConfDir: /etc/cni/net.d
    global:
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: ${cluster_name}
      network: ${network}
EOF
)"
  istioctl_install_with_openshift_patches "$ctx" "$op_yaml"
}

create_remote_secrets() {
  log "Creating remote secrets (east2 <-> west2)..."
  istioctl --context "$CTX_EAST" create-remote-secret --name "$CTX_EAST" \
    | kubectl --context "$CTX_WEST" apply -n "$ISTIO_NS" -f - >/dev/null
  istioctl --context "$CTX_WEST" create-remote-secret --name "$CTX_WEST" \
    | kubectl --context "$CTX_EAST" apply -n "$ISTIO_NS" -f - >/dev/null
}

ensure_istio_system_network_label() {
  local ctx="$1" network="$2"
  kubectl --context "$ctx" label namespace "$ISTIO_NS" "topology.istio.io/network=${network}" --overwrite >/dev/null 2>&1 || true
}

install_ambient_eastwest_gateway() {
  local ctx="$1" network="$2"
  log "Installing ambient east-west gateway on ${ctx} (network=${network})..."

  local minor url script_path
  minor="$(echo "$ISTIO_VERSION" | awk -F. '{print $1 "." $2}')"
  url="https://raw.githubusercontent.com/istio/istio/release-${minor}/samples/multicluster/gen-eastwest-gateway.sh"
  script_path="${ISTIO_CACHE_DIR}/${ISTIO_VERSION}/gen-eastwest-gateway.sh"

  mkdir -p "$(dirname "$script_path")"
  if [[ ! -s "$script_path" ]]; then
    curl -fsSL "$url" -o "$script_path"
    chmod +x "$script_path"
  fi

  # Clean up any previous eastwest gateway variants (Gateway API based, or earlier attempts).
  kubectl --context "$ctx" -n "$ISTIO_NS" delete gateway.gateway.networking.k8s.io istio-eastwestgateway --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n "$ISTIO_NS" delete deploy istio-eastwestgateway istio-eastwestgateway-istio --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n "$ISTIO_NS" delete svc istio-eastwestgateway istio-eastwestgateway-istio --ignore-not-found >/dev/null 2>&1 || true

  # Apply generated manifest (creates svc/deploy/sa/roles).
  "$script_path" --network "$network" --ambient | kubectl --context "$ctx" apply -n "$ISTIO_NS" -f - >/dev/null

  # OpenShift SCC: eastwest gateway runs with fixed UID.
  oc --context "$ctx" adm policy add-scc-to-user anyuid -n "$ISTIO_NS" -z istio-eastwestgateway-service-account >/dev/null 2>&1 || true

  kubectl --context "$ctx" -n "$ISTIO_NS" rollout status deploy/istio-eastwestgateway --timeout=300s >/dev/null

  # Multicluster ambient: the network gateway service must be global.
  kubectl --context "$ctx" -n "$ISTIO_NS" label svc istio-eastwestgateway istio.io/global=true --overwrite >/dev/null 2>&1 || true
}

wait_eastwest_lb_addr() {
  local ctx="$1"
  local addr=""
  for _ in {1..90}; do
    addr="$(kubectl --context "$ctx" -n "$ISTIO_NS" get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$addr" ]] && { echo "$addr"; return 0; }
    sleep 2
  done
  return 1
}

ensure_injector_network() {
  local ctx="$1" network="$2"
  log "Ensuring injector global.network=${network} on ${ctx}..."
  local patch
  patch="$(kubectl --context "$ctx" -n "$ISTIO_NS" get cm istio-sidecar-injector -o json 2>/dev/null | python3 -c '
import sys,json
cm=json.load(sys.stdin)
j=json.loads(cm["data"]["values"])
j.setdefault("global", {})["network"]=sys.argv[1]
new=json.dumps(j, indent=2, sort_keys=True)
print(json.dumps({"data":{"values":new}}))
' "$network")"
  kubectl --context "$ctx" -n "$ISTIO_NS" patch cm istio-sidecar-injector --type merge -p "$patch" >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n "$ISTIO_NS" rollout restart deploy/istiod >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n "$ISTIO_NS" rollout status deploy/istiod --timeout=300s >/dev/null 2>&1 || true
}

apply_mesh_networks() {
  local east_addr="$1" west_addr="$2"
  log "Configuring meshNetworks (required for cross-network failover)..."
  local east_ip west_ip
  east_ip="$(resolve_host_ip "$east_addr" || true)"
  west_ip="$(resolve_host_ip "$west_addr" || true)"
  [[ -n "$east_ip" ]] && east_addr="$east_ip"
  [[ -n "$west_ip" ]] && west_addr="$west_ip"

  local mn
  mn="$(cat <<EOF
networks:
  network1:
    endpoints:
    - fromRegistry: ${CTX_EAST}
    gateways:
    - address: ${east_addr}
      port: 15008
  network2:
    endpoints:
    - fromRegistry: ${CTX_WEST}
    gateways:
    - address: ${west_addr}
      port: 15008
EOF
)"

  for ctx in "$CTX_EAST" "$CTX_WEST"; do
    kubectl --context "$ctx" -n "$ISTIO_NS" patch cm istio --type merge \
      -p "$(python3 - <<PY
import json
print(json.dumps({"data":{"meshNetworks":"""$mn"""}}))
PY
)" >/dev/null
    # Ensure Istiod reloads the updated mesh networks config.
    kubectl --context "$ctx" -n "$ISTIO_NS" rollout restart deploy/istiod >/dev/null 2>&1 || true
    kubectl --context "$ctx" -n "$ISTIO_NS" rollout status deploy/istiod --timeout=300s >/dev/null 2>&1 || true
    # Restart ztunnel so it reconnects with updated network config.
    kubectl --context "$ctx" -n "$ISTIO_NS" rollout restart ds/ztunnel >/dev/null 2>&1 || true
    kubectl --context "$ctx" -n "$ISTIO_NS" rollout status ds/ztunnel --timeout=300s >/dev/null 2>&1 || true
  done
  log "meshNetworks configured."
}

main() {
  log "=== Istio upstream ${ISTIO_VERSION} ambient multicluster (east2/west2) ==="
  log "Contexts: east=${CTX_EAST}, west=${CTX_WEST}"
  log ""

  ensure_gateway_api_crds
  prepare_openshift_prereqs "$CTX_EAST"
  prepare_openshift_prereqs "$CTX_WEST"
  generate_cacerts
  apply_cacerts_secret "$CTX_EAST"
  apply_cacerts_secret "$CTX_WEST"

  ensure_istio_system_network_label "$CTX_EAST" "network1"
  ensure_istio_system_network_label "$CTX_WEST" "network2"

  install_istio_base "$CTX_EAST" "$CTX_EAST" "network1"
  install_istio_base "$CTX_WEST" "$CTX_WEST" "network2"

  ensure_injector_network "$CTX_EAST" "network1"
  ensure_injector_network "$CTX_WEST" "network2"

  create_remote_secrets

  install_ambient_eastwest_gateway "$CTX_EAST" "network1"
  install_ambient_eastwest_gateway "$CTX_WEST" "network2"

  # meshNetworks must include both networks and the gateway address for each.
  # Without this, cross-network routing (and failover) will not work: calls will fail when local endpoints go away.
  local east_addr west_addr
  east_addr="$(wait_eastwest_lb_addr "$CTX_EAST" || true)"
  west_addr="$(wait_eastwest_lb_addr "$CTX_WEST" || true)"
  [[ -n "$east_addr" && -n "$west_addr" ]] || die "east-west gateway LoadBalancer addresses not ready (east='${east_addr}', west='${west_addr}')"
  apply_mesh_networks "$east_addr" "$west_addr"

  log ""
  log "East-west gateway services:"
  log "  east: $(kubectl --context "$CTX_EAST" -n "$ISTIO_NS" get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')"
  log "  west: $(kubectl --context "$CTX_WEST" -n "$ISTIO_NS" get svc istio-eastwestgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')"
  log ""
  log "Next: deploy Bookinfo + waypoints:"
  log "  CTX_EAST=${CTX_EAST} CTX_WEST=${CTX_WEST} ./scripts/istio129/deploy-bookinfo.sh"
}

main "$@"

