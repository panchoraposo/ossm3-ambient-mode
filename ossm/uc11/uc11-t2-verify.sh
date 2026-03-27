#!/bin/bash
#
# UC11: Special Ciphers — Connectivity Link (Kuadrant) value add
#

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

PASS="${GREEN}✔${RESET}"
FAIL="${RED}✘${RESET}"
WARN="${YELLOW}⚠${RESET}"

CTX="${1:-east}"

UC_ID="${UC_ID:-UC11}"
UC_TITLE="${UC_TITLE:-Special Ciphers}"
UC_VARIANT="${UC_VARIANT:-Connectivity Link (Kuadrant)}"
UC_DIR="${UC_DIR:-ossm/uc11}"
RUN_HINT="${RUN_HINT:-./${0##*/}}"
ACM_CTX="${ACM_CTX:-acm}" # where centralized Kiali/Tempo live (if installed)

CLIENT_NS="${CLIENT_NS:-bookinfo}"
CLIENT_LABEL="${CLIENT_LABEL:-app=productpage}"
CLIENT_NS_FALLBACK="${CLIENT_NS_FALLBACK:-uc11-kuadrant-client}"
NO_PAUSE="${NO_PAUSE:-false}"
AUTO_ENABLE_DNS_CAPTURE="${AUTO_ENABLE_DNS_CAPTURE:-false}"
KEEP_RESOURCES="${KEEP_RESOURCES:-false}" # keep resources even on success (demo/Kiali)
WAIT_CLEANUP="${WAIT_CLEANUP:-true}"      # wait for namespaces to be fully deleted (safer for sequential runs)
CLEANUP_TIMEOUT_SEC="${CLEANUP_TIMEOUT_SEC:-300}"
WAIT_POLL_SEC="${WAIT_POLL_SEC:-2}"

KIALI_DEMO="${KIALI_DEMO:-false}"         # deploy background traffic generator + keep resources
# Where to deploy traffic generator. If unset, we set it after selecting a safe client namespace.
TRAFFIC_NS="${TRAFFIC_NS:-}"
TRAFFIC_PERIOD_SEC="${TRAFFIC_PERIOD_SEC:-2}"

# Demo enhancements (graph + traces)
ENABLE_CLIENT_WAYPOINT="${ENABLE_CLIENT_WAYPOINT:-auto}" # auto|true|false ; auto enables when KIALI_DEMO=true
CLIENT_WAYPOINT_NAME="${CLIENT_WAYPOINT_NAME:-uc11-kuadrant-client}"
CLIENT_WAYPOINT_CREATED="false"
DEDICATED_CLIENT_NS_CREATED="false"

# Kiali traces fetch fix for console proxy timeouts.
# Some Kiali builds add slow multi-cluster tag filters (istio.cluster_id) to Tempo queries, which can trigger 504s.
# If enabled, this patch disables Kiali multi-cluster autodetection so trace searches are faster.
KIALI_TRACES_PATCH="${KIALI_TRACES_PATCH:-false}" # true|false
KIALI_CTX="${KIALI_CTX:-${ACM_CTX}}"
KIALI_NS="${KIALI_NS:-istio-system}"
KIALI_TRACES_BACKUP_CM="${KIALI_TRACES_BACKUP_CM:-uc11-kuadrant-kiali-config-backup}"

BUILD_MODE="${BUILD_MODE:-binary}" # binary|git|prebuilt
GIT_REPO_URL="${GIT_REPO_URL:-}"
IMAGE_BUILD_NS="${IMAGE_BUILD_NS:-uc-images}" # non-ambient namespace to avoid polluting Kiali with build traffic

GIT_CONTEXT_LEGACY_TLS="${GIT_CONTEXT_LEGACY_TLS:-ossm/uc11/legacy-tls-server}"
GIT_CONTEXT_HAPROXY="${GIT_CONTEXT_HAPROXY:-ossm/uc11/legacy-haproxy-connector}"

LEGACY_NS="legacy-backend"
LEGACY_APP="legacy-tls"
LEGACY_SVC="legacy-tls"
LEGACY_PORT_TLS="8443"

EGRESS_NS="egress-legacy"
WAYPOINT_NAME="legacy-egress"

HOST_FRONT="legacy.bank.demo"
HOST_MODERN="legacy-modern.bank.demo"
HOST_COMPAT="legacy-compat.bank.demo"
DOWNGRADE_HEADER="x-bank-downgrade"

LEGACY_TLS_SERVER_IMAGE="${LEGACY_TLS_SERVER_IMAGE:-image-registry.openshift-image-registry.svc:5000/${IMAGE_BUILD_NS}/legacy-tls-server:latest}"
HAPROXY_CONNECTOR_IMAGE="${HAPROXY_CONNECTOR_IMAGE:-image-registry.openshift-image-registry.svc:5000/${IMAGE_BUILD_NS}/legacy-haproxy-connector:latest}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROBE_NS="legacy-probe"
PROBE_APP="legacy-probe"
PROBE_SVC="legacy-probe"
PROBE_PORT="8080"

GW_NS="api-gateway"
GW_NAME="legacy-api"
GW_CLASS="${GW_CLASS:-istio}"
ROUTE_NAME="legacy-api"
ROUTE_PATHS=("/modern" "/legacy")

HTTPROUTE_NAME="legacy-api-route"
AUTHPOLICY_NAME="legacy-api-legacy-only"
APIKEY_VALUE="${APIKEY_VALUE:-IAMLEGACY}"
APIKEY_PREFIX="${APIKEY_PREFIX:-APIKEY}"
APIKEY_LABEL_APP="${APIKEY_LABEL_APP:-legacy-tls-demo}"

pause() {
  if [[ "${NO_PAUSE}" == "true" ]]; then
    return 0
  fi
  echo ""
  echo -e "  ${CYAN}╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶${RESET}"
  read -rp "  ⏎ ${1:-Press ENTER to continue...} " _
}

wait_ns_deleted() {
  local ns="$1"
  local deadline=$(( $(date +%s) + CLEANUP_TIMEOUT_SEC ))
  while oc --context "$CTX" get ns "$ns" >/dev/null 2>&1; do
    if [[ $(date +%s) -ge $deadline ]]; then
      echo -e "  ${WARN} Namespace ${BOLD}${ns}${RESET} still exists (Terminating?) after ${CLEANUP_TIMEOUT_SEC}s"
      return 0
    fi
    sleep "${WAIT_POLL_SEC}"
  done
  return 0
}

header() {
  echo ""
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

section() {
  echo ""
  echo -e "${BOLD}▸ $1${RESET}"
}

ns_is_ambient() {
  local ns="$1"
  local mode
  mode="$(oc --context "$CTX" get ns "$ns" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || true)"
  [[ "${mode}" == "ambient" ]]
}

ensure_demo_client_ns() {
  # For Kiali demo, avoid touching bookinfo; create a dedicated ambient namespace for traffic generator.
  if [[ "${KIALI_DEMO}" != "true" ]]; then
    : "${TRAFFIC_NS:=${CLIENT_NS}}"
    return 0
  fi
  if [[ -n "${TRAFFIC_NS}" && "${TRAFFIC_NS}" != "bookinfo" ]]; then
    return 0
  fi

  local ns="${CLIENT_NS_FALLBACK}"
  section "Demo: create dedicated client namespace ${ns} (ambient) for traffic + traces"
  oc --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    istio.io/dataplane-mode: ambient
EOF
  DEDICATED_CLIENT_NS_CREATED="true"
  TRAFFIC_NS="${ns}"
}

ensure_client_waypoint_for_demo() {
  local enabled="${ENABLE_CLIENT_WAYPOINT}"
  if [[ "${enabled}" == "auto" ]]; then
    enabled="$([[ "${KIALI_DEMO}" == "true" ]] && echo true || echo false)"
  fi
  if [[ "${enabled}" != "true" ]]; then
    return 0
  fi
  if [[ "${DEDICATED_CLIENT_NS_CREATED}" != "true" ]]; then
    return 0
  fi
  section "Demo: create client waypoint (${TRAFFIC_NS}/${CLIENT_WAYPOINT_NAME}) for L7 graph + traces"
  istioctl --context "$CTX" waypoint apply --enroll-namespace --name "${CLIENT_WAYPOINT_NAME}" --namespace "${TRAFFIC_NS}" >/dev/null 2>&1 || true
  if oc --context "$CTX" wait --for=condition=Ready pod -n "${TRAFFIC_NS}" -l gateway.networking.k8s.io/gateway-name="${CLIENT_WAYPOINT_NAME}" --timeout=180s >/dev/null 2>&1; then
    CLIENT_WAYPOINT_CREATED="true"
    echo -e "  ${PASS} Client waypoint pod is Ready"
  else
    echo -e "  ${WARN} Client waypoint did not become Ready in time (traces may be limited)"
  fi
}
need_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo -e "  ${FAIL} Missing command: ${BOLD}${c}${RESET}"
    exit 1
  fi
}

kiali_patch_traces_if_needed() {
  if [[ "${KIALI_TRACES_PATCH}" != "true" ]]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  ${WARN} python3 not found; skipping Kiali traces patch."
    return 0
  fi

  section "Demo: patch Kiali config to speed up trace searches"
  echo -e "  Target: context=${BOLD}${KIALI_CTX}${RESET} namespace=${BOLD}${KIALI_NS}${RESET} configmap=${BOLD}kiali${RESET}"

  # Backup current config.yaml into a separate ConfigMap (so we can restore later).
  cfg="$(oc --context "${KIALI_CTX}" -n "${KIALI_NS}" get cm kiali -o jsonpath='{.data.config\\.yaml}' 2>/dev/null || true)"
  if [[ -z "${cfg}" ]]; then
    echo -e "  ${WARN} Could not read Kiali config.yaml; skipping patch."
    return 0
  fi

  oc --context "${KIALI_CTX}" -n "${KIALI_NS}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${KIALI_TRACES_BACKUP_CM}
  namespace: ${KIALI_NS}
  labels:
    app: uc11-demo
data:
  config.yaml: |
$(printf '%s\n' "${cfg}" | sed 's/^/    /')
EOF

  # Patch: disable multi-cluster autodetection to avoid adding istio.cluster_id tag filters in trace searches.
  patched="$(printf '%s\n' "${cfg}" | python3 - <<'PY'
import sys,re
s=sys.stdin.read()
s=re.sub(r'(^clustering:\n(?:[ ]{2}.*\n)*?[ ]{2}autodetect_secrets:\n(?:[ ]{4}.*\n)*?[ ]{4}enabled:)[ ]*true\b',
         r'\1 false', s, flags=re.M)
print(s)
PY
)"

  if [[ "${patched}" == "${cfg}" ]]; then
    echo -e "  ${WARN} Kiali config did not match expected pattern; no changes applied."
    echo -e "       Restore later (if needed): bash ossm/uc11/uc11-kiali-traces-restore.sh"
    return 0
  fi

  oc --context "${KIALI_CTX}" -n "${KIALI_NS}" patch cm kiali --type merge \
    -p "$(python3 - <<PY
import json
data={"data":{"config.yaml":"""${patched}""" }}
print(json.dumps(data))
PY
)" >/dev/null

  echo -e "  ${PASS} Patched Kiali configmap; restarting Kiali"
  oc --context "${KIALI_CTX}" -n "${KIALI_NS}" rollout restart deploy/kiali >/dev/null 2>&1 || true
  oc --context "${KIALI_CTX}" -n "${KIALI_NS}" rollout status deploy/kiali --timeout=180s >/dev/null 2>&1 || true
  echo -e "  ${PASS} Kiali restarted"
  echo -e "  ${CYAN}Restore later:${RESET} BACKUP_CM=${KIALI_TRACES_BACKUP_CM} bash ossm/uc11/uc11-kiali-traces-restore.sh"
}

build_legacy_image() {
  build_image "${IMAGE_BUILD_NS}" "legacy-tls-server" "${UC_DIR}/legacy-tls-server" "${GIT_CONTEXT_LEGACY_TLS}"
}

build_haproxy_image() {
  build_image "${IMAGE_BUILD_NS}" "legacy-haproxy-connector" "${UC_DIR}/legacy-haproxy-connector" "${GIT_CONTEXT_HAPROXY}"
}

detect_git_url() {
  local url=""
  if [[ -n "${GIT_REPO_URL}" ]]; then
    echo "${GIT_REPO_URL}"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  url="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    echo ""
    return 0
  fi
  if echo "${url}" | grep -qE '^git@github\.com:'; then
    url="$(echo "${url}" | sed -E 's#^git@github\.com:([^/]+)/(.+)$#https://github.com/\\1/\\2#')"
  fi
  if ! echo "${url}" | grep -qE '^https?://'; then
    echo ""
    return 0
  fi
  echo "${url}"
}

ensure_git_build() {
  local ns="$1"
  local name="$2"
  local context_dir="$3"
  local git_url="$4"

  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
EOF

  existing_type="$(oc --context "$CTX" -n "${ns}" get bc "${name}" -o jsonpath='{.spec.source.type}' 2>/dev/null || true)"
  if [[ -n "${existing_type}" && "${existing_type}" != "Git" ]]; then
    oc --context "$CTX" -n "${ns}" delete bc "${name}" >/dev/null 2>&1 || true
  fi

  oc --context "$CTX" -n "${ns}" apply -f - <<EOF >/dev/null
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${name}
  namespace: ${ns}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  runPolicy: Serial
  source:
    type: Git
    git:
      uri: ${git_url}
    contextDir: ${context_dir}
  strategy:
    type: Docker
    dockerStrategy: {}
  output:
    to:
      kind: ImageStreamTag
      name: ${name}:latest
EOF
}

ensure_binary_build() {
  local ns="$1"
  local name="$2"

  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
EOF

  existing_type="$(oc --context "$CTX" -n "${ns}" get bc "${name}" -o jsonpath='{.spec.source.type}' 2>/dev/null || true)"
  if [[ -n "${existing_type}" && "${existing_type}" != "Binary" ]]; then
    oc --context "$CTX" -n "${ns}" delete bc "${name}" >/dev/null 2>&1 || true
  fi
  oc --context "$CTX" -n "${ns}" get bc "${name}" >/dev/null 2>&1 || \
    oc --context "$CTX" -n "${ns}" new-build --name "${name}" --binary --strategy=docker >/dev/null
}

build_image() {
  local ns="$1"
  local name="$2"
  local local_dir="$3"
  local context_dir="$4"

  if [[ "${BUILD_MODE}" == "prebuilt" ]]; then
    echo -e "  ${PASS} BUILD_MODE=prebuilt — skipping build for ${BOLD}${ns}/${name}${RESET}"
    return 0
  fi

  if [[ "${BUILD_MODE}" == "git" ]]; then
    local git_url
    git_url="$(detect_git_url)"
    if [[ -n "${git_url}" ]]; then
      echo -e "  Building from Git source (${BOLD}${git_url}${RESET}, contextDir=${BOLD}${context_dir}${RESET})..."
      ensure_git_build "${ns}" "${name}" "${context_dir}" "${git_url}"
      oc --context "$CTX" -n "${ns}" start-build "${name}" --follow --wait >/dev/null
      return 0
    fi
    echo -e "  ${WARN} BUILD_MODE=git but could not detect GIT_REPO_URL; falling back to binary upload build."
  fi

  ensure_binary_build "${ns}" "${name}"
  echo -e "  Building from local dir upload (${BOLD}${local_dir}${RESET})..."
  oc --context "$CTX" -n "${ns}" start-build "${name}" --from-dir "${local_dir}" --follow --wait >/dev/null
}

ensure_image_puller() {
  local target_ns="$1"
  oc --context "$CTX" policy add-role-to-group system:image-puller "system:serviceaccounts:${target_ns}" -n "${IMAGE_BUILD_NS}" >/dev/null 2>&1 || true
}

detect_kuadrant_authpolicy_version() {
  local v
  v=$(oc --context "$CTX" get crd authpolicies.kuadrant.io -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null || true)
  if [[ -z "$v" ]]; then
    echo ""
    return 0
  fi
  echo "$v" | awk '{print $1}'
}

cleanup() {
  if [[ "${KEEP_RESOURCES}" == "true" ]] || [[ "${KIALI_DEMO}" == "true" ]]; then
    echo -e "  ${WARN} KEEP_RESOURCES=true/KIALI_DEMO=true — skipping cleanup"
    return 0
  fi
  oc --context "$CTX" delete deploy uc11-kuadrant-traffic -n "$TRAFFIC_NS" 2>/dev/null || true

  oc --context "$CTX" delete authpolicy "$AUTHPOLICY_NAME" -n "$PROBE_NS" 2>/dev/null || true
  oc --context "$CTX" delete httproute "$HTTPROUTE_NAME" -n "$PROBE_NS" 2>/dev/null || true
  oc --context "$CTX" delete route "$ROUTE_NAME" -n "$GW_NS" 2>/dev/null || true
  oc --context "$CTX" delete gateway "$GW_NAME" -n "$GW_NS" 2>/dev/null || true

  oc --context "$CTX" delete secret legacy-api-key -n kuadrant-system 2>/dev/null || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$GW_NS" --wait=false 2>/dev/null || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$PROBE_NS" --wait=false 2>/dev/null || true

  oc --context "$CTX" delete virtualservice legacy-downgrade-router -n "$EGRESS_NS" 2>/dev/null || true
  oc --context "$CTX" delete serviceentry legacy-front legacy -n "$EGRESS_NS" 2>/dev/null || true
  istioctl --context "$CTX" waypoint delete --namespace "$EGRESS_NS" "$WAYPOINT_NAME" >/dev/null 2>&1 || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$EGRESS_NS" --wait=false 2>/dev/null || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$LEGACY_NS" --wait=false 2>/dev/null || true

  if [[ "${DEDICATED_CLIENT_NS_CREATED}" == "true" ]]; then
    if [[ "${CLIENT_WAYPOINT_CREATED}" == "true" ]]; then
      istioctl --context "$CTX" waypoint delete --namespace "$TRAFFIC_NS" "$CLIENT_WAYPOINT_NAME" >/dev/null 2>&1 || true
    fi
    oc --context "$CTX" --request-timeout=10s delete namespace "$TRAFFIC_NS" --wait=false 2>/dev/null || true
  else
    oc --context "$CTX" delete deploy uc11-kuadrant-traffic -n "$TRAFFIC_NS" 2>/dev/null || true
  fi

  if [[ "${WAIT_CLEANUP}" == "true" ]]; then
    echo -e "  ${CYAN}Waiting for namespaces to be deleted (sequential-run safety)...${RESET}"
    wait_ns_deleted "$GW_NS"
    wait_ns_deleted "$PROBE_NS"
    wait_ns_deleted "$EGRESS_NS"
    wait_ns_deleted "$LEGACY_NS"
    if [[ "${DEDICATED_CLIENT_NS_CREATED}" == "true" ]]; then
      wait_ns_deleted "$TRAFFIC_NS"
    fi
  fi
}

trap cleanup EXIT

deploy_kiali_traffic_kuadrant() {
  local gw_svc="${GW_NAME}-istio.${GW_NS}.svc.cluster.local"
  local ns="${TRAFFIC_NS}"

  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uc11-kuadrant-traffic
  namespace: ${ns}
  labels:
    app: uc11-kuadrant-traffic
spec:
  replicas: 1
  selector:
    matchLabels:
      app: uc11-kuadrant-traffic
  template:
    metadata:
      labels:
        app: uc11-kuadrant-traffic
    spec:
      containers:
      - name: traffic
        image: registry.access.redhat.com/ubi9/python-311
        imagePullPolicy: IfNotPresent
        env:
        - name: GW_SVC
          value: "${gw_svc}"
        - name: HOST
          value: "${ROUTE_HOST}"
        - name: APIKEY_PREFIX
          value: "${APIKEY_PREFIX}"
        - name: APIKEY_VALUE
          value: "${APIKEY_VALUE}"
        - name: PERIOD
          value: "${TRAFFIC_PERIOD_SEC}"
        command: ["python3","-c"]
        args:
        - |
          import os, time, urllib.request, urllib.error
          gw=os.environ["GW_SVC"]
          host=os.environ["HOST"]
          pfx=os.environ.get("APIKEY_PREFIX","APIKEY")
          key=os.environ.get("APIKEY_VALUE","IAMLEGACY")
          period=float(os.environ.get("PERIOD","2"))
          def call(path, auth=False):
            url=f"http://{gw}{path}"
            headers={"Host": host}
            if auth:
              headers["Authorization"]=f"{pfx} {key}"
            req=urllib.request.Request(url, headers=headers)
            try:
              with urllib.request.urlopen(req, timeout=5) as r:
                r.read(64)
                return f"OK|{r.status}"
            except urllib.error.HTTPError as e:
              return f"HTTPERROR|{e.code}"
            except Exception as e:
              return f"ERROR|{type(e).__name__}|{e}"
          seq=[
            ("modern", "/modern", False),
            ("legacy_noauth", "/legacy", False),
            ("legacy_auth", "/legacy", True),
          ]
          i=0
          while True:
            name, path, auth = seq[i%len(seq)]
            i += 1
            print(f"{name}|{call(path, auth)}", flush=True)
            time.sleep(period)
EOF

  oc --context "$CTX" rollout status deploy/uc11-kuadrant-traffic -n "${ns}" --timeout=180s >/dev/null
  echo -e "  ${PASS} Background traffic generator deployed: ${BOLD}${ns}/uc11-kuadrant-traffic${RESET}"
  echo -e "  ${CYAN}Kiali tip:${RESET} open Graph for namespaces:"
  echo -e "    - ${BOLD}${ns}${RESET} (client)"
  echo -e "    - ${BOLD}${GW_NS}${RESET} (Gateway)"
  echo -e "    - ${BOLD}${PROBE_NS}${RESET} (legacy-probe)"
  echo -e "    - ${BOLD}${EGRESS_NS}${RESET} (waypoint + connectors)"
  echo -e "    - ${BOLD}${LEGACY_NS}${RESET} (backend)"
}

need_cmd oc
need_cmd istioctl
need_cmd curl

ensure_demo_client_ns
ensure_client_waypoint_for_demo

header "${UC_ID}: Legacy TLS Origination (${UC_TITLE}) — ${UC_VARIANT}"
echo -e "  Context: ${BOLD}${CTX}${RESET}"

section "Tracing prerequisites (for Kiali Traces)"
tracing_enabled="$(oc --context "$CTX" -n istio-system get istio default -o jsonpath='{.spec.values.meshConfig.enableTracing}' 2>/dev/null || true)"
tracing_sampling="$(oc --context "$CTX" -n istio-system get istio default -o jsonpath='{.spec.values.meshConfig.defaultConfig.tracing.sampling}' 2>/dev/null || true)"
if [[ "$tracing_enabled" == "true" ]]; then
  echo -e "  ${PASS} Istio tracing enabled (sampling=${BOLD}${tracing_sampling:-?}${RESET})"
else
  echo -e "  ${WARN} Istio tracing not detected in Istio CR (spec.values.meshConfig.enableTracing). Traces may not appear in Kiali."
fi
tempo_jaeger_host="$(oc --context "${ACM_CTX}" -n istio-system get route tempo-jaeger-query -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${tempo_jaeger_host}" ]]; then
  echo -e "  ${PASS} Tempo (Jaeger Query API) route: ${BOLD}https://${tempo_jaeger_host}${RESET}"
else
  echo -e "  ${WARN} Tempo route not found on context ${BOLD}${ACM_CTX}${RESET} (route tempo-jaeger-query)."
fi

# Optional: patch Kiali to avoid slow multi-cluster trace searches (504s).
kiali_patch_traces_if_needed

section "1. Verify prerequisites (DNS capture + Kuadrant CRDs)"
dns_capture=$(oc --context "$CTX" get istiocni default -o jsonpath='{.spec.values.cni.ambient.dnsCapture}' 2>/dev/null || true)
if [[ "$dns_capture" != "true" ]]; then
  if [[ "${AUTO_ENABLE_DNS_CAPTURE}" == "true" ]]; then
    echo -e "  ${WARN} DNS capture is ${YELLOW}${dns_capture:-unset}${RESET}. Enabling automatically (AUTO_ENABLE_DNS_CAPTURE=true)..."
    oc --context "$CTX" patch istiocni default --type merge \
      -p '{"spec":{"values":{"cni":{"ambient":{"dnsCapture":true}}}}}' >/dev/null

    echo -e "  ${PASS} Patched IstioCNI — restarting dataplane components"
    oc --context "$CTX" rollout restart ds/istio-cni-node -n istio-cni >/dev/null 2>&1 || true
    oc --context "$CTX" rollout restart ds/ztunnel -n ztunnel >/dev/null 2>&1 || true
    oc --context "$CTX" rollout restart deploy -n "$CLIENT_NS" >/dev/null 2>&1 || true

    oc --context "$CTX" rollout status ds/istio-cni-node -n istio-cni --timeout=180s >/dev/null 2>&1 || true
    oc --context "$CTX" rollout status ds/ztunnel -n ztunnel --timeout=180s >/dev/null 2>&1 || true
    oc --context "$CTX" rollout status deploy -n "$CLIENT_NS" --timeout=240s >/dev/null 2>&1 || true

    dns_capture=$(oc --context "$CTX" get istiocni default -o jsonpath='{.spec.values.cni.ambient.dnsCapture}' 2>/dev/null || true)
    if [[ "$dns_capture" != "true" ]]; then
      echo -e "  ${FAIL} DNS capture still not enabled after patch/restarts."
      exit 1
    fi
  else
    echo -e "  ${FAIL} DNS capture is ${RED}${dns_capture:-unset}${RESET}. This UC requires DNS capture."
    echo -e "     Fix options:"
    echo -e "     1) Re-run with auto-fix:"
    echo -e "        AUTO_ENABLE_DNS_CAPTURE=true ${RUN_HINT} ${CTX}"
    echo -e "     2) Or enable manually:"
    echo -e "        oc --context ${CTX} patch istiocni default --type merge -p '{\"spec\":{\"values\":{\"cni\":{\"ambient\":{\"dnsCapture\":true}}}}}'"
    echo -e "        oc --context ${CTX} rollout restart ds/istio-cni-node -n istio-cni"
    echo -e "        oc --context ${CTX} rollout restart ds/ztunnel -n ztunnel"
    echo -e "        oc --context ${CTX} rollout restart deploy -n ${CLIENT_NS}"
    exit 1
  fi
fi
echo -e "  ${PASS} DNS capture: ${GREEN}enabled${RESET}"

AUTH_VER=$(detect_kuadrant_authpolicy_version)
if [[ -z "$AUTH_VER" ]]; then
  echo -e "  ${FAIL} Kuadrant AuthPolicy CRD not found (authpolicies.kuadrant.io)."
  echo -e "     Ensure Connectivity Link/Kuadrant is installed in ${BOLD}kuadrant-system${RESET}."
  exit 1
fi
echo -e "  ${PASS} Kuadrant AuthPolicy version detected: ${BOLD}${AUTH_VER}${RESET}"

pause "Press ENTER to deploy legacy backend + egress TLS origination (same as UC11 Istio-only)..."

header "Phase: Legacy backend + egress TLS origination"
section "2. Deploy legacy backend (TLS1.0 only) in ${LEGACY_NS}"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${LEGACY_NS}
EOF

section "2.1 Build legacy TLS server image (UBI7 + openssl)"
build_legacy_image
ensure_image_puller "${LEGACY_NS}"

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${LEGACY_APP}
  namespace: ${LEGACY_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${LEGACY_APP}
  template:
    metadata:
      labels:
        app: ${LEGACY_APP}
    spec:
      containers:
      - name: tls
        image: ${LEGACY_TLS_SERVER_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: ${LEGACY_PORT_TLS}
          name: tls
        env:
        - name: PORT
          value: "${LEGACY_PORT_TLS}"
        - name: HOSTNAME_CN
          value: "${HOST_FRONT}"
        - name: TLS_FLAG
          value: "-tls1"
        - name: CIPHER
          value: "ECDHE-RSA-AES256-SHA"
EOF

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${LEGACY_SVC}
  namespace: ${LEGACY_NS}
spec:
  selector:
    app: ${LEGACY_APP}
  ports:
  - name: tls
    port: ${LEGACY_PORT_TLS}
    targetPort: ${LEGACY_PORT_TLS}
EOF

oc --context "$CTX" rollout status deploy/${LEGACY_APP} -n "${LEGACY_NS}" --timeout=240s >/dev/null
LEGACY_SVC_IP=$(oc --context "$CTX" get svc/${LEGACY_SVC} -n "${LEGACY_NS}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
echo -e "  ${PASS} Legacy backend IP: ${BOLD}${LEGACY_SVC_IP}${RESET}:${LEGACY_PORT_TLS}"

section "3. Create egress namespace + waypoint (${EGRESS_NS}/${WAYPOINT_NAME})"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${EGRESS_NS}
  labels:
    istio.io/dataplane-mode: ambient
EOF

istioctl --context "$CTX" waypoint apply --enroll-namespace --name "${WAYPOINT_NAME}" --namespace "${EGRESS_NS}" >/dev/null 2>&1 || true
oc --context "$CTX" wait --for=condition=Ready pod -n "${EGRESS_NS}" -l gateway.networking.k8s.io/gateway-name="${WAYPOINT_NAME}" --timeout=120s >/dev/null

section "3.1 Build HAProxy connector image (UBI7 + haproxy)"
build_haproxy_image
ensure_image_puller "${EGRESS_NS}"

section "4. Apply ServiceEntry + HAProxy connectors + VirtualService (downgrade by header)"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: legacy-front
  namespace: ${EGRESS_NS}
spec:
  exportTo:
  - "*"
  hosts:
  - ${HOST_FRONT}
  ports:
  - number: 80
    name: http
    protocol: HTTP
  # DNS capture answers VIPs only for ServiceEntries with resolution DNS.
  resolution: DNS
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: legacy-connector-modern
  namespace: ${EGRESS_NS}
data:
  haproxy.cfg: |
    global
      maxconn 1024
    defaults
      mode http
      timeout connect 5s
      timeout client  30s
      timeout server  30s
    frontend fe
      bind *:8080
      default_backend be
    backend be
      server legacy ${LEGACY_SVC_IP}:${LEGACY_PORT_TLS} ssl verify none force-tlsv12
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: legacy-connector-compat
  namespace: ${EGRESS_NS}
data:
  haproxy.cfg: |
    global
      maxconn 1024
    defaults
      mode http
      timeout connect 5s
      timeout client  30s
      timeout server  30s
    frontend fe
      bind *:8080
      default_backend be
    backend be
      server legacy ${LEGACY_SVC_IP}:${LEGACY_PORT_TLS} ssl verify none force-tlsv10 ciphers ECDHE-RSA-AES256-SHA
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-connector-modern
  namespace: ${EGRESS_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-connector-modern
  template:
    metadata:
      labels:
        app: legacy-connector-modern
    spec:
      containers:
      - name: haproxy
        image: ${HAPROXY_CONNECTOR_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: cfg
          mountPath: /etc/haproxy
      volumes:
      - name: cfg
        configMap:
          name: legacy-connector-modern
---
apiVersion: v1
kind: Service
metadata:
  name: legacy-connector-modern
  namespace: ${EGRESS_NS}
spec:
  selector:
    app: legacy-connector-modern
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-connector-compat
  namespace: ${EGRESS_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-connector-compat
  template:
    metadata:
      labels:
        app: legacy-connector-compat
    spec:
      containers:
      - name: haproxy
        image: ${HAPROXY_CONNECTOR_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: cfg
          mountPath: /etc/haproxy
      volumes:
      - name: cfg
        configMap:
          name: legacy-connector-compat
---
apiVersion: v1
kind: Service
metadata:
  name: legacy-connector-compat
  namespace: ${EGRESS_NS}
spec:
  selector:
    app: legacy-connector-compat
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: legacy-downgrade-router
  namespace: ${EGRESS_NS}
spec:
  hosts:
  - ${HOST_FRONT}
  http:
  - match:
    - headers:
        ${DOWNGRADE_HEADER}:
          exact: "true"
    route:
    - destination:
        host: legacy-connector-compat.${EGRESS_NS}.svc.cluster.local
        port:
          number: 8080
  - route:
    - destination:
        host: legacy-connector-modern.${EGRESS_NS}.svc.cluster.local
        port:
          number: 8080
EOF
echo -e "  ${PASS} Egress TLS origination configured"
oc --context "$CTX" rollout status deploy/legacy-connector-modern -n "${EGRESS_NS}" --timeout=180s >/dev/null
oc --context "$CTX" rollout status deploy/legacy-connector-compat -n "${EGRESS_NS}" --timeout=180s >/dev/null
sleep 20

pause "Press ENTER to deploy 'legacy-probe' service in mesh..."

header "Phase: Mesh service that calls the legacy endpoint"
section "5. Deploy ${PROBE_APP} (ambient) in ${PROBE_NS}"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${PROBE_NS}
  labels:
    istio.io/dataplane-mode: ambient
EOF

oc --context "$CTX" apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: legacy-probe-app
  namespace: legacy-probe
data:
  app.py: |
    import json
    import os
    import urllib.request
    import urllib.error
    from http.server import BaseHTTPRequestHandler, HTTPServer

    UPSTREAM = os.environ.get("UPSTREAM_URL", "http://legacy.bank.demo/")
    DOWNGRADE_HEADER = os.environ.get("DOWNGRADE_HEADER", "x-bank-downgrade")

    class Handler(BaseHTTPRequestHandler):
        def _write(self, code, payload):
            body = json.dumps(payload, indent=2).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            incoming = {k.lower(): v for k, v in self.headers.items()}
            hdr = {}
            if incoming.get(DOWNGRADE_HEADER, "").lower() == "true":
                hdr[DOWNGRADE_HEADER] = "true"

            req = urllib.request.Request(UPSTREAM, headers=hdr)
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = resp.read(200).decode(errors="ignore")
                    self._write(200, {
                        "path": self.path,
                        "upstream": UPSTREAM,
                        "downgrade_header_forwarded": hdr.get(DOWNGRADE_HEADER, ""),
                        "upstream_status": resp.status,
                        "upstream_body_snippet": data.replace("\n", " ")[:200],
                    })
            except urllib.error.HTTPError as e:
                self._write(502, {
                    "path": self.path,
                    "upstream": UPSTREAM,
                    "downgrade_header_forwarded": hdr.get(DOWNGRADE_HEADER, ""),
                    "error": "HTTPError",
                    "status": e.code,
                    "body_snippet": e.read().decode(errors="ignore")[:200],
                })
            except Exception as e:
                self._write(502, {
                    "path": self.path,
                    "upstream": UPSTREAM,
                    "downgrade_header_forwarded": hdr.get(DOWNGRADE_HEADER, ""),
                    "error": type(e).__name__,
                    "message": str(e),
                })

    if __name__ == "__main__":
        port = int(os.environ.get("PORT", "8080"))
        httpd = HTTPServer(("0.0.0.0", port), Handler)
        print(f"legacy-probe listening on :{port}, upstream={UPSTREAM}, header={DOWNGRADE_HEADER}", flush=True)
        httpd.serve_forever()
EOF

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROBE_APP}
  namespace: ${PROBE_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROBE_APP}
  template:
    metadata:
      labels:
        app: ${PROBE_APP}
    spec:
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/python-311
        imagePullPolicy: IfNotPresent
        env:
        - name: PORT
          value: "${PROBE_PORT}"
        - name: UPSTREAM_URL
          value: "http://${HOST_FRONT}/"
        - name: DOWNGRADE_HEADER
          value: "${DOWNGRADE_HEADER}"
        ports:
        - containerPort: ${PROBE_PORT}
          name: http
        volumeMounts:
        - name: app
          mountPath: /app
        command: ["python","-u","/app/app.py"]
      volumes:
      - name: app
        configMap:
          name: legacy-probe-app
EOF

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${PROBE_SVC}
  namespace: ${PROBE_NS}
spec:
  selector:
    app: ${PROBE_APP}
  ports:
  - name: http
    port: ${PROBE_PORT}
    targetPort: ${PROBE_PORT}
EOF

oc --context "$CTX" rollout status deploy/${PROBE_APP} -n "${PROBE_NS}" --timeout=180s >/dev/null
echo -e "  ${PASS} ${PROBE_APP} is Ready"

pause "Press ENTER to expose it via Gateway API + Kuadrant AuthPolicy..."

header "Phase: Edge Gateway + Kuadrant AuthPolicy"
section "6. Create Gateway in ${GW_NS} (GatewayClass=${GW_CLASS}) + OpenShift Route"

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${GW_NS}
EOF

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${GW_NS}
  labels:
    kuadrant.io/gateway: "true"
spec:
  gatewayClassName: ${GW_CLASS}
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF

echo -e "  Waiting for gateway service to exist..."
for i in $(seq 1 60); do
  if oc --context "$CTX" get svc -n "$GW_NS" "${GW_NAME}-istio" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! oc --context "$CTX" get svc -n "$GW_NS" "${GW_NAME}-istio" >/dev/null 2>&1; then
  echo -e "  ${FAIL} Gateway Service ${BOLD}${GW_NAME}-istio${RESET} not found. Check GatewayClass=${GW_CLASS}."
  exit 1
fi

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${ROUTE_NAME}
  namespace: ${GW_NS}
spec:
  to:
    kind: Service
    name: ${GW_NAME}-istio
  port:
    targetPort: 80
EOF

ROUTE_HOST=$(oc --context "$CTX" get route "${ROUTE_NAME}" -n "${GW_NS}" -o jsonpath='{.spec.host}' 2>/dev/null)
echo -e "  ${PASS} Route host: ${BOLD}${ROUTE_HOST}${RESET}"

section "7. Create HTTPRoute with 2 rules (modern vs legacy header injection)"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${HTTPROUTE_NAME}
  namespace: ${PROBE_NS}
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GW_NAME}
    namespace: ${GW_NS}
  hostnames:
  - ${ROUTE_HOST}
  rules:
  - name: modern
    matches:
    - path:
        type: PathPrefix
        value: /modern
    backendRefs:
    - name: ${PROBE_SVC}
      port: ${PROBE_PORT}
  - name: legacy
    matches:
    - path:
        type: PathPrefix
        value: /legacy
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        add:
        - name: ${DOWNGRADE_HEADER}
          value: "true"
    backendRefs:
    - name: ${PROBE_SVC}
      port: ${PROBE_PORT}
EOF

section "8. Create API key Secret + Kuadrant AuthPolicy (protect legacy path)"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: legacy-api-key
  namespace: kuadrant-system
  labels:
    authorino.kuadrant.io/managed-by: authorino
    app: ${APIKEY_LABEL_APP}
stringData:
  api_key: ${APIKEY_VALUE}
type: Opaque
EOF

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: kuadrant.io/${AUTH_VER}
kind: AuthPolicy
metadata:
  name: ${AUTHPOLICY_NAME}
  namespace: ${GW_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GW_NAME}
  when:
  - predicate: "request.path.startsWith('/legacy')"
  rules:
    authentication:
      "api-key-users":
        apiKey:
          selector:
            matchLabels:
              app: ${APIKEY_LABEL_APP}
          allNamespaces: true
        credentials:
          authorizationHeader:
            prefix: ${APIKEY_PREFIX}
EOF

echo -e "  ${PASS} HTTPRoute + AuthPolicy applied"
echo -e "  Waiting 30s for Kuadrant propagation..."
sleep 30

pause "Press ENTER to run edge tests..."

if [[ "${KIALI_DEMO}" == "true" ]]; then
  header "Kiali demo mode enabled"
  section "Deploy background traffic (modern vs legacy with/without auth)"
  deploy_kiali_traffic_kuadrant
  echo ""
  echo -e "  ${WARN} Resources are being kept for demo (KIALI_DEMO=true)."
  echo -e "  To cleanup later, delete ONLY demo namespaces (safe):"
  echo -e "    oc --context ${CTX} delete ns ${TRAFFIC_NS} ${GW_NS} ${PROBE_NS} ${EGRESS_NS} ${LEGACY_NS} --wait=false"
  echo -e "  Or run the cleanup helper:"
  echo -e "    bash ossm/uc11/uc11-kuadrant-demo-cleanup.sh ${CTX}"
  echo ""
  echo -e "  ${CYAN}Kiali graph namespaces:${RESET}"
  echo -e "    - ${BOLD}${TRAFFIC_NS}${RESET} (client)"
  echo -e "    - ${BOLD}${GW_NS}${RESET} (Gateway)"
  echo -e "    - ${BOLD}${PROBE_NS}${RESET} (legacy-probe)"
  echo -e "    - ${BOLD}${EGRESS_NS}${RESET} (waypoint + connectors)"
  echo -e "    - ${BOLD}${LEGACY_NS}${RESET} (backend)"
  echo -e "  ${CYAN}Traces tip:${RESET}"
  echo -e "    - ${BOLD}401 (unauthorized)${RESET} is enforced at the edge Gateway."
  echo -e "      Look in Kiali at: ${BOLD}${GW_NS}${RESET} -> ${BOLD}Workloads${RESET} -> ${BOLD}legacy-api-istio${RESET} -> Traces."
  echo -e "      (In this Kiali build, ${BOLD}Services -> Traces${RESET} may show 'No traces' due to a bad Tempo query like ${BOLD}service=.${GW_NS}${RESET}.)"
  echo -e "      Alternative: ${BOLD}View in Tracing${RESET} and search for service ${BOLD}legacy-api-istio.${GW_NS}${RESET}."
  echo -e "    - If Traces listing fails with ${BOLD}504${RESET} (timeout), re-run with:"
  echo -e "      ${BOLD}KIALI_TRACES_PATCH=true${RESET} (restorable via ${BOLD}ossm/uc11/uc11-kiali-traces-restore.sh${RESET})."
  echo -e "    - ${BOLD}200${RESET} (authorized) and strict-path failures (5xx) continue downstream and can be seen at:"
  echo -e "      - waypoint ${BOLD}${EGRESS_NS}/${WAYPOINT_NAME}${RESET}"
  echo -e "      - ${BOLD}${LEGACY_NS}/${LEGACY_APP}${RESET}"
  exit 0
fi

header "Phase: Edge tests (value-add)"

section "9. Call /modern (no auth, no downgrade header) — expected FAIL"
modern_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${ROUTE_HOST}/modern" || true)
echo -e "  /modern status: ${BOLD}${modern_code}${RESET}"

section "10. Call /legacy without auth — expected 401"
legacy_noauth_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${ROUTE_HOST}/legacy" || true)
echo -e "  /legacy (no auth) status: ${BOLD}${legacy_noauth_code}${RESET}"

if [[ "${legacy_noauth_code}" != "401" ]]; then
  echo -e "  ${WARN} AuthPolicy did not enforce /legacy-only. Falling back to protect ALL gateway traffic..."
  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: kuadrant.io/${AUTH_VER}
kind: AuthPolicy
metadata:
  name: ${AUTHPOLICY_NAME}
  namespace: ${GW_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GW_NAME}
  rules:
    authentication:
      "api-key-users":
        apiKey:
          selector:
            matchLabels:
              app: ${APIKEY_LABEL_APP}
          allNamespaces: true
        credentials:
          authorizationHeader:
            prefix: ${APIKEY_PREFIX}
EOF
  echo -e "  Waiting 15s for propagation..."
  sleep 15
  legacy_noauth_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${ROUTE_HOST}/legacy" || true)
  echo -e "  /legacy (no auth) status (after fallback): ${BOLD}${legacy_noauth_code}${RESET}"
fi

section "11. Call /legacy WITH API key — expected 200"
legacy_auth_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: ${APIKEY_PREFIX} ${APIKEY_VALUE}" "http://${ROUTE_HOST}/legacy" || true)
echo -e "  /legacy (auth) status: ${BOLD}${legacy_auth_code}${RESET}"

section "12. Show payload for /legacy (auth) (should include upstream_status=200)"
curl -s -H "Authorization: ${APIKEY_PREFIX} ${APIKEY_VALUE}" "http://${ROUTE_HOST}/legacy" | sed 's/^/    /' || true

section "13. Validate negotiated cipher in legacy backend logs"
LEGACY_POD=$(oc --context "$CTX" get pod -n "${LEGACY_NS}" -l app="${LEGACY_APP}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
log_snip=$(oc --context "$CTX" logs -n "${LEGACY_NS}" "$LEGACY_POD" --tail=800 2>/dev/null | grep -E "TLS 1\\.0 Handshake|Protocol  :|CIPHER is" | tail -n 12 || true)
if [[ -n "$log_snip" ]]; then
  echo -e "  ${PASS} Legacy TLS server observed:"
  echo "$log_snip" | sed 's/^/    /'
  test_cipher="pass"
else
  echo -e "  ${WARN} Could not find TLS1.0/cipher markers in recent logs"
  test_cipher="warn"
fi

pause "Press ENTER to cleanup..."

trap - EXIT
cleanup

header "Results"
echo ""
echo -e "  | Check                        | Expected | Got  | Result |"
echo -e "  |-----------------------------|----------|------|--------|"
printf "  | /modern (no auth)            | non-200  | %s  | %b |\n" \
  "$modern_code" "$([ "$modern_code" != "200" ] && echo -e "${PASS}" || echo -e "${WARN}")"
printf "  | /legacy without auth         | 401      | %s  | %b |\n" \
  "$legacy_noauth_code" "$([ "$legacy_noauth_code" = "401" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | /legacy with API key         | 200      | %s  | %b |\n" \
  "$legacy_auth_code" "$([ "$legacy_auth_code" = "200" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | legacy TLS cipher visible    | present  |  -   | %b |\n" \
  "$([ "$test_cipher" = "pass" ] && echo -e "${PASS}" || echo -e "${WARN}")"
echo ""

echo -e "  ${BOLD}Meaning (for Kiali/Traces):${RESET}"
echo -e "    - ${BOLD}/modern${RESET}: should typically be ${BOLD}503/504/ERROR${RESET} (strict TLS path → legacy TLS1.0 backend fails)"
echo -e "    - ${BOLD}/legacy without auth${RESET}: ${BOLD}401${RESET} (Kuadrant AuthPolicy rejects missing API key)"
echo -e "    - ${BOLD}/legacy with API key${RESET}: ${BOLD}200${RESET} (authorized + downgrade header injected → compat path succeeds)"
echo ""

if [[ "$legacy_noauth_code" = "401" && "$legacy_auth_code" = "200" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}${UC_ID} PASSED${RESET} — Kuadrant controls access to the legacy downgrade path"
else
  echo -e "  ${FAIL} ${RED}${BOLD}${UC_ID} FAILED${RESET} — unexpected HTTP statuses"
fi
echo ""

