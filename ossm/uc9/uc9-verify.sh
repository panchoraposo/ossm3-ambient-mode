#!/bin/bash
#
# UC9: Special Case of Custom Certificate — Ambient (OSSM 3.2)
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

RUN_HINT="${RUN_HINT:-./ossm/uc9-verify.sh}"
ACM_CTX="${ACM_CTX:-acm}" # where centralized Kiali/Tempo live (if installed)
KIALI_CTX="${KIALI_CTX:-${ACM_CTX}}"
KIALI_NS="${KIALI_NS:-istio-system}"

CLIENT_NS="${CLIENT_NS:-bookinfo}"
CLIENT_LABEL="${CLIENT_LABEL:-app=productpage}"
CLIENT_NS_FALLBACK="${CLIENT_NS_FALLBACK:-uc9-client}"
AUTO_ENABLE_DNS_CAPTURE="${AUTO_ENABLE_DNS_CAPTURE:-false}"
KEEP_RESOURCES_ON_FAIL="${KEEP_RESOURCES_ON_FAIL:-false}"
KEEP_RESOURCES="${KEEP_RESOURCES:-false}" # keep resources even on success (demo/Kiali)
NO_PAUSE="${NO_PAUSE:-false}"
CLIENT_MODE="${CLIENT_MODE:-auto}" # auto|force-client-pod
WAIT_CLEANUP="${WAIT_CLEANUP:-true}"      # wait for namespaces to be fully deleted (safer for sequential runs)
CLEANUP_TIMEOUT_SEC="${CLEANUP_TIMEOUT_SEC:-300}"
WAIT_POLL_SEC="${WAIT_POLL_SEC:-2}"

HOST_FRONT="customcert.bank.demo"
CUSTOM_CA_HEADER="${CUSTOM_CA_HEADER:-x-bank-custom-ca}"

BACKEND_NS="custom-cert-backend"
BACKEND_APP="custom-cert"
BACKEND_SVC="custom-cert"
BACKEND_PORT_TLS="8443"

EGRESS_NS="egress-custom-cert"
WAYPOINT_NAME="custom-cert-egress"

KIALI_DEMO="${KIALI_DEMO:-false}"        # deploy background traffic generator + keep resources
TRAFFIC_PERIOD_SEC="${TRAFFIC_PERIOD_SEC:-2}"
# Where to deploy background traffic. If unset, we set it after selecting the client namespace.
TRAFFIC_NS="${TRAFFIC_NS:-}"

# Demo enhancements (graph + traces)
ENABLE_CLIENT_WAYPOINT="${ENABLE_CLIENT_WAYPOINT:-auto}" # auto|true|false ; auto enables when KIALI_DEMO=true
CLIENT_WAYPOINT_NAME="${CLIENT_WAYPOINT_NAME:-uc9-client}"
CLIENT_WAYPOINT_CREATED="false"

# Kiali tracing fetch fix for console proxy timeouts.
# In some environments Kiali multi-cluster trace searches add tags (istio.cluster_id) which can make Tempo searches slow,
# causing the OpenShift console proxy to return 504.
# If enabled, this patch disables Kiali multi-cluster autodetection so trace searches are faster.
KIALI_TRACES_PATCH="${KIALI_TRACES_PATCH:-false}" # true|false
KIALI_TRACES_BACKUP_CM="${KIALI_TRACES_BACKUP_CM:-uc9-kiali-config-backup}"

BUILD_MODE="${BUILD_MODE:-binary}" # binary|git|prebuilt
GIT_REPO_URL="${GIT_REPO_URL:-}"
IMAGE_BUILD_NS="${IMAGE_BUILD_NS:-uc-images}" # non-ambient namespace to avoid polluting Kiali with build traffic
FALLBACK_TO_BINARY_ON_GIT_FAIL="${FALLBACK_TO_BINARY_ON_GIT_FAIL:-true}"

SERVER_IMG_NAME="custom-cert-server"
SERVER_BUILD_DIR="${SERVER_BUILD_DIR:-ossm/uc9/custom-cert-server}"
HAPROXY_IMG_NAME="uc9-haproxy-connector"
HAPROXY_BUILD_DIR="${HAPROXY_BUILD_DIR:-ossm/uc9/haproxy-connector}"

CUSTOM_CERT_SERVER_IMAGE="${CUSTOM_CERT_SERVER_IMAGE:-image-registry.openshift-image-registry.svc:5000/${IMAGE_BUILD_NS}/uc9-custom-cert-server:latest}"
HAPROXY_IMAGE="${HAPROXY_IMAGE:-image-registry.openshift-image-registry.svc:5000/${IMAGE_BUILD_NS}/uc9-haproxy-connector:latest}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

ensure_client_waypoint_for_demo() {
  # Create a waypoint in the *client* namespace for L7 visibility/traces.
  # Only ever applied to the dedicated demo namespace (never to bookinfo).
  local ns="${CLIENT_NS}"

  local enabled="${ENABLE_CLIENT_WAYPOINT}"
  if [[ "${enabled}" == "auto" ]]; then
    if [[ "${KIALI_DEMO}" == "true" ]]; then
      enabled="true"
    else
      enabled="false"
    fi
  fi
  if [[ "${enabled}" != "true" ]]; then
    return 0
  fi

  if [[ "${DEDICATED_CLIENT_NS_CREATED}" != "true" ]]; then
    return 0
  fi

  section "Demo: create client waypoint (${ns}/${CLIENT_WAYPOINT_NAME}) for L7 graph + traces"
  istioctl --context "$CTX" waypoint apply --enroll-namespace --name "${CLIENT_WAYPOINT_NAME}" --namespace "${ns}" >/dev/null 2>&1 || true
  if oc --context "$CTX" wait --for=condition=Ready pod -n "${ns}" -l gateway.networking.k8s.io/gateway-name="${CLIENT_WAYPOINT_NAME}" --timeout=180s >/dev/null 2>&1; then
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
    app: uc9-demo
data:
  config.yaml: |
$(printf '%s\n' "${cfg}" | sed 's/^/    /')
EOF

  # Patch: disable multi-cluster autodetection to avoid adding istio.cluster_id tag filters in trace searches.
  patched="$(printf '%s\n' "${cfg}" | python3 - <<'PY'
import sys,re
s=sys.stdin.read()
# Replace only the specific 'clustering.autodetect_secrets.enabled: true' if present.
s=re.sub(r'(^clustering:\\n(?:[ ]{2}.*\\n)*?[ ]{2}autodetect_secrets:\\n(?:[ ]{4}.*\\n)*?[ ]{4}enabled:)[ ]*true\\b',
         r'\\1 false', s, flags=re.M)
print(s)
PY
)"

  if [[ "${patched}" == "${cfg}" ]]; then
    echo -e "  ${WARN} Kiali config did not match expected pattern; no changes applied."
    echo -e "       You can restore with: bash ossm/uc9/uc9-kiali-traces-restore.sh"
    return 0
  fi

  oc --context "${KIALI_CTX}" -n "${KIALI_NS}" patch cm kiali --type merge \
    -p "$(python3 - <<PY
import json,sys
data={"data":{"config.yaml":"""${patched}""" }}
print(json.dumps(data))
PY
)" >/dev/null

  echo -e "  ${PASS} Patched Kiali configmap; restarting Kiali"
  oc --context "${KIALI_CTX}" -n "${KIALI_NS}" rollout restart deploy/kiali >/dev/null 2>&1 || true
  oc --context "${KIALI_CTX}" -n "${KIALI_NS}" rollout status deploy/kiali --timeout=180s >/dev/null 2>&1 || true
  echo -e "  ${PASS} Kiali restarted"
  echo -e "  ${CYAN}Restore later:${RESET} bash ossm/uc9/uc9-kiali-traces-restore.sh"
}

TMPDIR=""
DEDICATED_CLIENT_NS_CREATED="false"
cleanup() {
  if [[ -n "${TMPDIR}" && -d "${TMPDIR}" ]]; then
    rm -rf "${TMPDIR}" || true
  fi

  if [[ "${KEEP_RESOURCES}" == "true" ]] || [[ "${KIALI_DEMO}" == "true" ]]; then
    echo -e "  ${WARN} KEEP_RESOURCES=true/KIALI_DEMO=true — skipping cleanup"
    return 0
  fi
  if [[ "${KEEP_RESOURCES_ON_FAIL}" == "true" ]]; then
    echo -e "  ${WARN} KEEP_RESOURCES_ON_FAIL=true — skipping cleanup"
    return 0
  fi

  oc --context "$CTX" delete virtualservice custom-cert-router -n "$EGRESS_NS" 2>/dev/null || true
  oc --context "$CTX" delete serviceentry custom-cert-front -n "$EGRESS_NS" 2>/dev/null || true
  istioctl --context "$CTX" waypoint delete --namespace "$EGRESS_NS" "$WAYPOINT_NAME" >/dev/null 2>&1 || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$EGRESS_NS" --wait=false 2>/dev/null || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$BACKEND_NS" --wait=false 2>/dev/null || true
  oc --context "$CTX" delete deploy uc9-traffic -n "$TRAFFIC_NS" 2>/dev/null || true
  if [[ "${DEDICATED_CLIENT_NS_CREATED}" == "true" ]]; then
    if [[ "${CLIENT_WAYPOINT_CREATED}" == "true" ]]; then
      istioctl --context "$CTX" waypoint delete --namespace "$CLIENT_NS_FALLBACK" "$CLIENT_WAYPOINT_NAME" >/dev/null 2>&1 || true
    fi
    oc --context "$CTX" --request-timeout=10s delete namespace "$CLIENT_NS_FALLBACK" --wait=false 2>/dev/null || true
  else
    oc --context "$CTX" delete pod custom-cert-client -n "$CLIENT_NS" 2>/dev/null || true
  fi

  if [[ "${WAIT_CLEANUP}" == "true" ]]; then
    echo -e "  ${CYAN}Waiting for namespaces to be deleted (sequential-run safety)...${RESET}"
    wait_ns_deleted "$EGRESS_NS"
    wait_ns_deleted "$BACKEND_NS"
    if [[ "${DEDICATED_CLIENT_NS_CREATED}" == "true" ]]; then
      wait_ns_deleted "$CLIENT_NS_FALLBACK"
    fi
  fi
}

trap cleanup EXIT

need_cmd oc
need_cmd istioctl
need_cmd openssl
need_cmd base64
need_cmd tr

header "UC9: Special Case of Custom Certificate — custom CA trust only for one destination"
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

deploy_kiali_traffic_uc9() {
  local ns="${TRAFFIC_NS}"
  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uc9-traffic
  namespace: ${ns}
  labels:
    app: uc9-traffic
spec:
  replicas: 1
  selector:
    matchLabels:
      app: uc9-traffic
  template:
    metadata:
      labels:
        app: uc9-traffic
    spec:
      containers:
      - name: traffic
        image: registry.access.redhat.com/ubi9/python-311
        imagePullPolicy: IfNotPresent
        env:
        - name: HOST
          value: "${HOST_FRONT}"
        - name: HDR_NAME
          value: "${CUSTOM_CA_HEADER}"
        - name: PERIOD
          value: "${TRAFFIC_PERIOD_SEC}"
        command: ["python3","-c"]
        args:
        - |
          import os, time, urllib.request, urllib.error
          host=os.environ["HOST"]
          hdr=os.environ.get("HDR_NAME","x-bank-custom-ca")
          period=float(os.environ.get("PERIOD","2"))
          urls=[("nohdr", {}), ("hdr", {hdr:"true"})]
          i=0
          while True:
            tag, headers = urls[i%2]
            i += 1
            req=urllib.request.Request(f"http://{host}/", headers=headers)
            try:
              with urllib.request.urlopen(req, timeout=5) as r:
                r.read(64)
                print(f"{tag}|{r.status}")
            except urllib.error.HTTPError as e:
              print(f"{tag}|HTTPERROR|{e.code}")
            except Exception as e:
              print(f"{tag}|ERROR|{type(e).__name__}|{e}")
            time.sleep(period)
EOF
  oc --context "$CTX" rollout status deploy/uc9-traffic -n "${ns}" --timeout=180s >/dev/null
  echo -e "  ${PASS} Background traffic generator deployed: ${BOLD}${ns}/uc9-traffic${RESET}"
  echo -e "  ${CYAN}Kiali tip:${RESET} open Graph for namespaces:"
  echo -e "    - ${BOLD}${ns}${RESET} (client)"
  echo -e "    - ${BOLD}${EGRESS_NS}${RESET} (waypoint + connectors)"
  echo -e "    - ${BOLD}${BACKEND_NS}${RESET} (backend)"
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
  # Convert SSH URL to https://github.com/org/repo(.git)
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

ensure_image_puller() {
  local target_ns="$1"
  oc --context "$CTX" policy add-role-to-group system:image-puller "system:serviceaccounts:${target_ns}" -n "${IMAGE_BUILD_NS}" >/dev/null 2>&1 || true
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
      if oc --context "$CTX" -n "${ns}" start-build "${name}" --follow --wait >/dev/null; then
        return 0
      fi
      if [[ "${FALLBACK_TO_BINARY_ON_GIT_FAIL}" != "true" ]]; then
        echo -e "  ${FAIL} Git build failed and FALLBACK_TO_BINARY_ON_GIT_FAIL!=true"
        exit 1
      fi
      echo -e "  ${WARN} Git build failed (often missing contextDir in remote). Falling back to binary upload build..."
    fi
    echo -e "  ${WARN} BUILD_MODE=git but could not detect GIT_REPO_URL; falling back to binary upload build."
  fi

  ensure_binary_build "${ns}" "${name}"
  echo -e "  Building from local dir upload (${BOLD}${local_dir}${RESET})..."
  oc --context "$CTX" -n "${ns}" start-build "${name}" --from-dir "${local_dir}" --follow --wait >/dev/null
}

section "1. Verify prerequisites (client + DNS capture)"
PRODUCTPAGE_POD=""
orig_client_ns="${CLIENT_NS}"

if [[ "${CLIENT_MODE}" != "force-client-pod" ]]; then
  PRODUCTPAGE_POD=$(oc --context "$CTX" get pods -n "$CLIENT_NS" -l "$CLIENT_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [[ "${KIALI_DEMO}" == "true" && "${CLIENT_NS}" == "bookinfo" ]]; then
  # In demo mode we must NOT depend on bookinfo being ambient-enrolled (often it's not).
  PRODUCTPAGE_POD=""
fi

if [[ -n "${PRODUCTPAGE_POD}" ]] && ! ns_is_ambient "${CLIENT_NS}"; then
  # DNS capture for ServiceEntry VIPs requires the client to be in ambient dataplane-mode.
  echo -e "  ${WARN} Found client pod in ${BOLD}${CLIENT_NS}${RESET}, but namespace is not labeled ${BOLD}istio.io/dataplane-mode=ambient${RESET}."
  echo -e "       Using dedicated ambient client namespace ${BOLD}${CLIENT_NS_FALLBACK}${RESET} (no changes to ${BOLD}${orig_client_ns}${RESET})."
  PRODUCTPAGE_POD=""
fi

if [[ -z "${PRODUCTPAGE_POD}" ]]; then
  echo -e "  ${WARN} Could not find ${BOLD}${CLIENT_NS}${RESET} pod with label ${BOLD}${CLIENT_LABEL}${RESET}."
  echo -e "       Creating a dedicated ambient client pod in ${BOLD}${CLIENT_NS_FALLBACK}${RESET}..."

  CLIENT_NS="${CLIENT_NS_FALLBACK}"
  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${CLIENT_NS}
  labels:
    istio.io/dataplane-mode: ambient
EOF

  DEDICATED_CLIENT_NS_CREATED="true"
  PRODUCTPAGE_POD="custom-cert-client"
  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${PRODUCTPAGE_POD}
  namespace: ${CLIENT_NS}
  labels:
    app: custom-cert-client
spec:
  restartPolicy: Never
  containers:
  - name: client
    image: registry.access.redhat.com/ubi9/python-311
    imagePullPolicy: IfNotPresent
    command: ["sh","-lc"]
    args: ["sleep 3600"]
EOF
  oc --context "$CTX" wait --for=condition=Ready pod/${PRODUCTPAGE_POD} -n "${CLIENT_NS}" --timeout=180s >/dev/null
  echo -e "  ${PASS} Client pod (dedicated): ${BOLD}${CLIENT_NS}/${PRODUCTPAGE_POD}${RESET}"
else
  echo -e "  ${PASS} Client pod: ${BOLD}${CLIENT_NS}/${PRODUCTPAGE_POD}${RESET}"
fi

# Default traffic namespace to selected client namespace (safe for cleanup; never suggests deleting bookinfo).
: "${TRAFFIC_NS:=${CLIENT_NS}}"

# Optional: patch Kiali config to avoid trace-search 504s via console proxy.
kiali_patch_traces_if_needed

# For demo, create a client waypoint so Kiali can show L7 edges + traces reliably.
ensure_client_waypoint_for_demo

dns_capture=$(oc --context "$CTX" get istiocni default -o jsonpath='{.spec.values.cni.ambient.dnsCapture}' 2>/dev/null || true)
if [[ "$dns_capture" != "true" ]]; then
  if [[ "${AUTO_ENABLE_DNS_CAPTURE}" == "true" ]]; then
    echo -e "  ${WARN} DNS capture is ${YELLOW}${dns_capture:-unset}${RESET}. Enabling automatically (AUTO_ENABLE_DNS_CAPTURE=true)..."
    oc --context "$CTX" patch istiocni default --type merge \
      -p '{"spec":{"values":{"cni":{"ambient":{"dnsCapture":true}}}}}' >/dev/null
    oc --context "$CTX" rollout restart ds/istio-cni-node -n istio-cni >/dev/null 2>&1 || true
    oc --context "$CTX" rollout restart ds/ztunnel -n ztunnel >/dev/null 2>&1 || true
    oc --context "$CTX" rollout restart deploy -n "$CLIENT_NS" >/dev/null 2>&1 || true
    oc --context "$CTX" rollout status ds/ztunnel -n ztunnel --timeout=180s >/dev/null 2>&1 || true
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
    exit 1
  fi
fi
echo -e "  ${PASS} DNS capture: ${GREEN}enabled${RESET}"

pause "Press ENTER to generate a custom CA + server cert and deploy the backend..."

header "Phase: Custom cert backend"
section "2. Generate custom CA + server certificate (SAN: ${HOST_FRONT})"
TMPDIR="$(mktemp -d)"
CA_KEY="${TMPDIR}/ca.key"
CA_CRT="${TMPDIR}/ca.crt"
SRV_KEY="${TMPDIR}/tls.key"
SRV_CSR="${TMPDIR}/server.csr"
SRV_CRT="${TMPDIR}/tls.crt"
EXT_CNF="${TMPDIR}/openssl.cnf"

cat > "${EXT_CNF}" <<EOF
[req]
distinguished_name = dn
req_extensions = req_ext
prompt = no

[dn]
CN = ${HOST_FRONT}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${HOST_FRONT}
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=Bank Demo CA" \
  -keyout "${CA_KEY}" -out "${CA_CRT}" >/dev/null 2>&1

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "${SRV_KEY}" -out "${SRV_CSR}" \
  -config "${EXT_CNF}" >/dev/null 2>&1

openssl x509 -req -days 365 \
  -in "${SRV_CSR}" -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
  -out "${SRV_CRT}" -extensions req_ext -extfile "${EXT_CNF}" >/dev/null 2>&1

echo -e "  ${PASS} Generated certs in ${BOLD}${TMPDIR}${RESET}"

section "3. Deploy backend namespace + TLS secret"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${BACKEND_NS}
EOF

CRT_B64="$(base64 < "${SRV_CRT}" | tr -d '\n')"
KEY_B64="$(base64 < "${SRV_KEY}" | tr -d '\n')"
CA_B64="$(base64 < "${CA_CRT}" | tr -d '\n')"

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: custom-cert-tls
  namespace: ${BACKEND_NS}
type: Opaque
data:
  tls.crt: ${CRT_B64}
  tls.key: ${KEY_B64}
  ca.crt: ${CA_B64}
EOF

section "4. Build backend image (UBI7 + openssl)"
if [[ ! -d "${SERVER_BUILD_DIR}" ]]; then
  echo -e "  ${FAIL} Missing build directory: ${BOLD}${SERVER_BUILD_DIR}${RESET}"
  exit 1
fi
echo -e "  Building image ${BOLD}${BACKEND_NS}/${SERVER_IMG_NAME}:latest${RESET}..."
build_image "${IMAGE_BUILD_NS}" "uc9-custom-cert-server" "${SERVER_BUILD_DIR}" "ossm/uc9/custom-cert-server"
ensure_image_puller "${BACKEND_NS}"

section "5. Deploy backend (TLS server uses custom cert)"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${BACKEND_APP}
  namespace: ${BACKEND_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${BACKEND_APP}
  template:
    metadata:
      labels:
        app: ${BACKEND_APP}
    spec:
      containers:
      - name: server
        image: ${CUSTOM_CERT_SERVER_IMAGE}
        imagePullPolicy: Always
        env:
        - name: PORT
          value: "${BACKEND_PORT_TLS}"
        ports:
        - containerPort: ${BACKEND_PORT_TLS}
          name: tls
        volumeMounts:
        - name: tls
          mountPath: /etc/tls
          readOnly: true
      volumes:
      - name: tls
        secret:
          secretName: custom-cert-tls
---
apiVersion: v1
kind: Service
metadata:
  name: ${BACKEND_SVC}
  namespace: ${BACKEND_NS}
spec:
  selector:
    app: ${BACKEND_APP}
  ports:
  - name: tls
    port: ${BACKEND_PORT_TLS}
    targetPort: ${BACKEND_PORT_TLS}
EOF

if ! oc --context "$CTX" rollout status deploy/${BACKEND_APP} -n "${BACKEND_NS}" --timeout=240s >/dev/null; then
  echo -e "  ${FAIL} Backend did not become Ready in time."
  oc --context "$CTX" get pods -n "${BACKEND_NS}" -o wide || true
  exit 1
fi
echo -e "  ${PASS} Backend Ready: ${BOLD}${BACKEND_NS}/${BACKEND_APP}${RESET}"

pause "Press ENTER to configure egress waypoint + routing..."

header "Phase: Ambient egress + per-destination custom CA"
section "6. Create egress namespace + waypoint (${EGRESS_NS}/${WAYPOINT_NAME})"
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
EGRESS_WP_POD=$(oc --context "$CTX" get pod -n "${EGRESS_NS}" -l gateway.networking.k8s.io/gateway-name="${WAYPOINT_NAME}" -o jsonpath='{.items[0].metadata.name}')
echo -e "  ${PASS} Egress waypoint pod: ${BOLD}${EGRESS_WP_POD}${RESET}"

section "6.1 Build HAProxy connector image (UBI7 + haproxy)"
if [[ ! -d "${HAPROXY_BUILD_DIR}" ]]; then
  echo -e "  ${FAIL} Missing build directory: ${BOLD}${HAPROXY_BUILD_DIR}${RESET}"
  exit 1
fi
echo -e "  Building image ${BOLD}${EGRESS_NS}/${HAPROXY_IMG_NAME}:latest${RESET}..."
build_image "${IMAGE_BUILD_NS}" "uc9-haproxy-connector" "${HAPROXY_BUILD_DIR}" "ossm/uc9/haproxy-connector"
ensure_image_puller "${EGRESS_NS}"

section "7. Create ServiceEntry (front) to capture DNS: ${HOST_FRONT}"
oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: custom-cert-front
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
  resolution: DNS
EOF

sleep 5
front_vip=$(oc --context "$CTX" get serviceentry custom-cert-front -n "${EGRESS_NS}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
echo -e "  ${PASS} ServiceEntry VIP: ${BOLD}${front_vip:-unknown}${RESET}"

section "8. Deploy connectors (strict vs custom-ca) + VirtualService routing"
BACKEND_FQDN="${BACKEND_SVC}.${BACKEND_NS}.svc.cluster.local"

CA_SECRET_B64="$(oc --context "$CTX" get secret custom-cert-tls -n "${BACKEND_NS}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
if [[ -z "${CA_SECRET_B64}" ]]; then
  echo -e "  ${FAIL} Could not read ca.crt from secret ${BACKEND_NS}/custom-cert-tls"
  exit 1
fi

oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: custom-ca
  namespace: ${EGRESS_NS}
type: Opaque
data:
  ca.crt: ${CA_SECRET_B64}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-cert-connector-strict
  namespace: ${EGRESS_NS}
data:
  haproxy.cfg: |
    global
      maxconn 1024
    defaults
      mode http
      timeout connect 5s
      timeout client 30s
      timeout server 30s
    frontend fe
      bind :8080
      default_backend be
    backend be
      http-request set-header Host ${HOST_FRONT}
      # "Strict": verify required using system CA bundle (will NOT trust our custom CA)
      server s1 ${BACKEND_FQDN}:${BACKEND_PORT_TLS} ssl verify required ca-file /etc/pki/tls/certs/ca-bundle.crt
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: custom-cert-connector-strict
  namespace: ${EGRESS_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: custom-cert-connector-strict
  template:
    metadata:
      labels:
        app: custom-cert-connector-strict
    spec:
      containers:
      - name: haproxy
        image: ${HAPROXY_IMAGE}
        imagePullPolicy: Always
        env:
        - name: CFG
          value: /etc/haproxy/haproxy.cfg
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: cfg
          mountPath: /etc/haproxy
          readOnly: true
      volumes:
      - name: cfg
        configMap:
          name: custom-cert-connector-strict
          items:
          - key: haproxy.cfg
            path: haproxy.cfg
---
apiVersion: v1
kind: Service
metadata:
  name: custom-cert-connector-strict
  namespace: ${EGRESS_NS}
spec:
  selector:
    app: custom-cert-connector-strict
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-cert-connector-customca
  namespace: ${EGRESS_NS}
data:
  haproxy.cfg: |
    global
      maxconn 1024
    defaults
      mode http
      timeout connect 5s
      timeout client 30s
      timeout server 30s
    frontend fe
      bind :8080
      default_backend be
    backend be
      http-request set-header Host ${HOST_FRONT}
      server s1 ${BACKEND_FQDN}:${BACKEND_PORT_TLS} ssl verify required ca-file /etc/custom-ca/ca.crt
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: custom-cert-connector-customca
  namespace: ${EGRESS_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: custom-cert-connector-customca
  template:
    metadata:
      labels:
        app: custom-cert-connector-customca
    spec:
      containers:
      - name: haproxy
        image: ${HAPROXY_IMAGE}
        imagePullPolicy: Always
        env:
        - name: CFG
          value: /etc/haproxy/haproxy.cfg
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: cfg
          mountPath: /etc/haproxy
          readOnly: true
        - name: ca
          mountPath: /etc/custom-ca
          readOnly: true
      volumes:
      - name: cfg
        configMap:
          name: custom-cert-connector-customca
          items:
          - key: haproxy.cfg
            path: haproxy.cfg
      - name: ca
        secret:
          secretName: custom-ca
---
apiVersion: v1
kind: Service
metadata:
  name: custom-cert-connector-customca
  namespace: ${EGRESS_NS}
spec:
  selector:
    app: custom-cert-connector-customca
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: custom-cert-router
  namespace: ${EGRESS_NS}
spec:
  hosts:
  - ${HOST_FRONT}
  http:
  - match:
    - headers:
        ${CUSTOM_CA_HEADER}:
          exact: "true"
    route:
    - destination:
        host: custom-cert-connector-customca.${EGRESS_NS}.svc.cluster.local
        port:
          number: 8080
  - route:
    - destination:
        host: custom-cert-connector-strict.${EGRESS_NS}.svc.cluster.local
        port:
          number: 8080
EOF

if ! oc --context "$CTX" rollout status deploy/custom-cert-connector-strict -n "${EGRESS_NS}" --timeout=240s >/dev/null; then
  echo -e "  ${FAIL} strict connector did not become Ready in time."
  oc --context "$CTX" get pods -n "${EGRESS_NS}" -o wide || true
  pod=$(oc --context "$CTX" get pod -n "${EGRESS_NS}" -l app=custom-cert-connector-strict -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${pod}" ]]; then
    echo -e "  ${CYAN}Describe pod/${pod}:${RESET}"
    oc --context "$CTX" describe pod -n "${EGRESS_NS}" "${pod}" || true
    echo -e "  ${CYAN}Logs pod/${pod}:${RESET}"
    oc --context "$CTX" logs -n "${EGRESS_NS}" "${pod}" --tail=200 || true
  fi
  echo -e "  Tip: re-run with ${BOLD}KEEP_RESOURCES_ON_FAIL=true${RESET} to keep namespaces for inspection."
  exit 1
fi

if ! oc --context "$CTX" rollout status deploy/custom-cert-connector-customca -n "${EGRESS_NS}" --timeout=240s >/dev/null; then
  echo -e "  ${FAIL} custom-ca connector did not become Ready in time."
  oc --context "$CTX" get pods -n "${EGRESS_NS}" -o wide || true
  pod=$(oc --context "$CTX" get pod -n "${EGRESS_NS}" -l app=custom-cert-connector-customca -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${pod}" ]]; then
    echo -e "  ${CYAN}Describe pod/${pod}:${RESET}"
    oc --context "$CTX" describe pod -n "${EGRESS_NS}" "${pod}" || true
    echo -e "  ${CYAN}Logs pod/${pod}:${RESET}"
    oc --context "$CTX" logs -n "${EGRESS_NS}" "${pod}" --tail=200 || true
  fi
  echo -e "  Tip: re-run with ${BOLD}KEEP_RESOURCES_ON_FAIL=true${RESET} to keep namespaces for inspection."
  exit 1
fi
echo -e "  ${PASS} Connectors Ready"

section "9. Run tests from client (no header should FAIL; header should succeed)"

run_client_http() {
  local header_value="${1:-}"
  local pod="${PRODUCTPAGE_POD}"

  if [[ "${CLIENT_MODE}" == "force-client-pod" ]] || ! oc --context "$CTX" exec -n "$CLIENT_NS" "$pod" -- sh -lc 'command -v python3 >/dev/null 2>&1' >/dev/null 2>&1; then
    pod="custom-cert-client"
    oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${CLIENT_NS}
  labels:
    app: custom-cert-client
spec:
  restartPolicy: Never
  containers:
  - name: client
    image: registry.access.redhat.com/ubi9/python-311
    imagePullPolicy: IfNotPresent
    command: ["sh","-lc"]
    args: ["sleep 3600"]
EOF
    oc --context "$CTX" wait --for=condition=Ready pod/${pod} -n "${CLIENT_NS}" --timeout=180s >/dev/null
  fi

  oc --context "$CTX" exec -n "$CLIENT_NS" "$pod" -- env HOST="${HOST_FRONT}" HDR="${header_value}" HDRNAME="${CUSTOM_CA_HEADER}" python3 -c '
import os, urllib.request, urllib.error
url = "http://%s/" % os.environ["HOST"]
hdr = os.environ.get("HDR", "")
hdrname = os.environ.get("HDRNAME", "x-bank-custom-ca")
headers = {}
if hdr:
  headers[hdrname] = hdr
req = urllib.request.Request(url, headers=headers)
try:
  with urllib.request.urlopen(req, timeout=10) as resp:
    body = resp.read(120).decode(errors="ignore").replace("\n", " ")[:120]
    print(f"OK|{resp.status}|{body}")
except urllib.error.HTTPError as e:
  print("HTTPERROR|{}|{}".format(e.code, e.read().decode("utf-8","ignore")[:120]))
except Exception as e:
  print(f"ERROR|{type(e).__name__}|{e}")
' 2>&1 || true
}

nohdr="$(run_client_http "")"
hdr="$(run_client_http "true")"

echo -e "  No header:   ${BOLD}${nohdr}${RESET}"
echo -e "  With header: ${BOLD}${hdr}${RESET}"

extract_http_code() {
  local s="$1"
  if echo "$s" | grep -qE '^OK\\|[0-9]{3}\\|'; then
    echo "$s" | awk -F'|' '{print $2}'
    return 0
  fi
  if echo "$s" | grep -qE '^HTTPERROR\\|[0-9]{3}\\|'; then
    echo "$s" | awk -F'|' '{print $2}'
    return 0
  fi
  echo "ERROR"
}

nohdr_code="$(extract_http_code "$nohdr")"
hdr_code="$(extract_http_code "$hdr")"

ok_nohdr="fail"
ok_hdr="fail"
if [[ "${nohdr_code}" != "200" ]]; then ok_nohdr="pass"; fi
if [[ "${hdr_code}" == "200" ]]; then ok_hdr="pass"; fi

pause "Press ENTER to cleanup..."

if [[ "${KIALI_DEMO}" == "true" ]]; then
  header "Kiali demo mode enabled"
  section "Deploy background traffic (alternates strict vs custom-ca)"
  deploy_kiali_traffic_uc9
  echo ""
  echo -e "  ${WARN} Resources are being kept for demo (KIALI_DEMO=true)."
  echo -e "  To cleanup later, delete ONLY the demo namespaces (safe):"
  echo -e "    oc --context ${CTX} delete ns ${CLIENT_NS} ${EGRESS_NS} ${BACKEND_NS} --wait=false"
  echo -e "  Or run the cleanup helper:"
  echo -e "    bash ossm/uc9/uc9-demo-cleanup.sh ${CTX}"
  echo ""
  echo -e "  ${CYAN}Kiali graph namespaces:${RESET}"
  echo -e "    - ${BOLD}${CLIENT_NS}${RESET} (client)"
  echo -e "    - ${BOLD}${EGRESS_NS}${RESET} (waypoint + connectors)"
  echo -e "    - ${BOLD}${BACKEND_NS}${RESET} (backend)"
  echo ""
  echo -e "  ${CYAN}Traces tip:${RESET}"
  echo -e "    - Traces are emitted by the ${BOLD}waypoints (Envoy)${RESET}, not by the HAProxy connector pods."
  echo -e "    - In the Kiali graph, click the triangle waypoint nodes:"
  echo -e "      - ${BOLD}${EGRESS_NS}/${WAYPOINT_NAME}${RESET} (egress waypoint)"
  echo -e "      - ${BOLD}${CLIENT_NS}/${CLIENT_WAYPOINT_NAME}${RESET} (client waypoint)"
  echo -e "    - Then open the ${BOLD}Traces${RESET} tab and click ${BOLD}Show Traces${RESET} (Last 5m)."
  echo -e "    - You should see requests for host ${BOLD}${HOST_FRONT}${RESET}."
  echo -e "    - If you still see ${BOLD}504${RESET} errors in the UI, re-run with:"
  echo -e "      ${BOLD}KIALI_TRACES_PATCH=true${RESET} (and later restore using uc9-kiali-traces-restore.sh)."
  echo -e "  ${CYAN}Note:${RESET} this script does not modify or require deleting ${BOLD}bookinfo${RESET}."
  exit 0
fi

trap - EXIT
cleanup

header "Results"
echo ""
echo -e "  | Check                                 | Expected | Got  | Meaning (for Kiali/Traces) |"
echo -e "  |---------------------------------------|----------|------|----------------------------|"
printf   "  | Default path (no header)              | FAIL     | %s  | strict connector: no custom CA trust → TLS failure / upstream unavailable |\n" \
  "$nohdr_code"
printf   "  | Custom-CA path (header ${CUSTOM_CA_HEADER}=true) | 200 OK   | %s  | custom-ca connector: custom CA trust injected → success |\n" \
  "$hdr_code"
echo ""

if [[ "$ok_nohdr" = "pass" && "$ok_hdr" = "pass" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC9 PASSED${RESET} — custom CA trust is enabled only for the special destination"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC9 FAILED${RESET} — unexpected HTTP results"
  exit 1
fi
echo ""

header "HTTP codes you should expect"
echo ""
echo -e "  - ${BOLD}200${RESET}: custom CA path works (header set)"
echo -e "  - ${BOLD}503/504/ERROR${RESET}: strict path fails (header missing) — typically TLS handshake or timeout through egress"
echo -e "  - ${BOLD}If you see 000/timeout in clients${RESET}: it usually means DNS capture/ServiceEntry/waypoint path is not ready yet"
echo ""

