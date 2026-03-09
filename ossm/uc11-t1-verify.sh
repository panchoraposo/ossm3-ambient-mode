#!/bin/bash
#
# UC11: Special Ciphers — Istio-only (Ambient)
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
UC_DIR="${UC_DIR:-ossm/uc11}"
RUN_HINT="${RUN_HINT:-./${0##*/}}"

CLIENT_NS="${CLIENT_NS:-bookinfo}"
CLIENT_LABEL="${CLIENT_LABEL:-app=productpage}"
AUTO_ENABLE_DNS_CAPTURE="${AUTO_ENABLE_DNS_CAPTURE:-false}"
KEEP_RESOURCES_ON_FAIL="${KEEP_RESOURCES_ON_FAIL:-false}"
KEEP_RESOURCES="${KEEP_RESOURCES:-false}" # keep resources even on success (demo/Kiali)
NO_PAUSE="${NO_PAUSE:-false}"
CLIENT_MODE="${CLIENT_MODE:-auto}" # auto|force-client-pod

KIALI_DEMO="${KIALI_DEMO:-false}"         # deploy background traffic generator + keep resources
TRAFFIC_NS="${TRAFFIC_NS:-${CLIENT_NS}}" # where to deploy traffic generator (prefer bookinfo)
TRAFFIC_PERIOD_SEC="${TRAFFIC_PERIOD_SEC:-2}"

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

pause() {
  if [[ "${NO_PAUSE}" == "true" ]]; then
    return 0
  fi
  echo ""
  echo -e "  ${CYAN}╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶${RESET}"
  read -rp "  ⏎ ${1:-Press ENTER to continue...} " _
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

need_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo -e "  ${FAIL} Missing command: ${BOLD}${c}${RESET}"
    exit 1
  fi
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

run_client_http() {
  local header_value="${1:-}"
  local pod="${PRODUCTPAGE_POD}"

  if [[ "${CLIENT_MODE}" == "force-client-pod" ]] || ! oc --context "$CTX" exec -n "$CLIENT_NS" "$pod" -- sh -lc 'command -v python3 >/dev/null 2>&1' >/dev/null 2>&1; then
    pod="legacy-client"
    oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${CLIENT_NS}
  labels:
    app: legacy-client
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

  oc --context "$CTX" exec -n "$CLIENT_NS" "$pod" -- env HOST="${HOST_FRONT}" HDR="${header_value}" python3 -c '
import os, urllib.request, urllib.error
url = "http://%s/" % os.environ["HOST"]
hdr = os.environ.get("HDR", "")
headers = {}
if hdr:
  headers["x-bank-downgrade"] = hdr
req = urllib.request.Request(url, headers=headers)
try:
  with urllib.request.urlopen(req, timeout=10) as resp:
    body = resp.read(180).decode(errors="ignore").replace("\n", " ")[:180]
    print(f"OK|{resp.status}|{body}")
except urllib.error.HTTPError as e:
  print("HTTPERROR|{}|{}".format(e.code, e.read().decode("utf-8","ignore")[:180]))
except Exception as e:
  print(f"ERROR|{type(e).__name__}|{e}")
' 2>&1 || true
}

cleanup() {
  if [[ "${KEEP_RESOURCES}" == "true" ]] || [[ "${KIALI_DEMO}" == "true" ]]; then
    echo -e "  ${WARN} KEEP_RESOURCES=true/KIALI_DEMO=true — skipping cleanup"
    return 0
  fi
  if [[ "${KEEP_RESOURCES_ON_FAIL}" == "true" ]]; then
    echo -e "  ${WARN} KEEP_RESOURCES_ON_FAIL=true — skipping cleanup"
    return 0
  fi
  oc --context "$CTX" delete deploy uc11-traffic -n "$TRAFFIC_NS" 2>/dev/null || true
  oc --context "$CTX" delete virtualservice legacy-downgrade-router -n "$EGRESS_NS" 2>/dev/null || true
  oc --context "$CTX" delete serviceentry legacy-front legacy -n "$EGRESS_NS" 2>/dev/null || true
  istioctl --context "$CTX" waypoint delete --namespace "$EGRESS_NS" "$WAYPOINT_NAME" >/dev/null 2>&1 || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$EGRESS_NS" --wait=false 2>/dev/null || true
  oc --context "$CTX" --request-timeout=10s delete namespace "$LEGACY_NS" --wait=false 2>/dev/null || true
  oc --context "$CTX" delete pod legacy-client -n "$CLIENT_NS" 2>/dev/null || true
}

trap cleanup EXIT

deploy_kiali_traffic() {
  local ns="${TRAFFIC_NS}"
  oc --context "$CTX" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uc11-traffic
  namespace: ${ns}
  labels:
    app: uc11-traffic
spec:
  replicas: 1
  selector:
    matchLabels:
      app: uc11-traffic
  template:
    metadata:
      labels:
        app: uc11-traffic
    spec:
      containers:
      - name: traffic
        image: registry.access.redhat.com/ubi9/python-311
        imagePullPolicy: IfNotPresent
        env:
        - name: HOST
          value: "${HOST_FRONT}"
        - name: HDR_NAME
          value: "${DOWNGRADE_HEADER}"
        - name: PERIOD
          value: "${TRAFFIC_PERIOD_SEC}"
        command: ["python3","-c"]
        args:
        - |
          import os, time, urllib.request, urllib.error
          host=os.environ["HOST"]
          hdr=os.environ.get("HDR_NAME","x-bank-downgrade")
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
  oc --context "$CTX" rollout status deploy/uc11-traffic -n "${ns}" --timeout=180s >/dev/null
  echo -e "  ${PASS} Background traffic generator deployed: ${BOLD}${ns}/uc11-traffic${RESET}"
  echo -e "  ${CYAN}Kiali tip:${RESET} open Graph for namespaces:"
  echo -e "    - ${BOLD}${ns}${RESET} (client)"
  echo -e "    - ${BOLD}${EGRESS_NS}${RESET} (waypoint + connectors)"
  echo -e "    - ${BOLD}${LEGACY_NS}${RESET} (backend)"
}

need_cmd oc
need_cmd istioctl

header "${UC_ID}: Legacy TLS Origination (${UC_TITLE}) — Istio-only"
echo -e "  Context: ${BOLD}${CTX}${RESET}"

section "1. Verify prerequisites (bookinfo + DNS capture)"
PRODUCTPAGE_POD=$(oc --context "$CTX" get pods -n "$CLIENT_NS" -l "$CLIENT_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${PRODUCTPAGE_POD}" ]]; then
  echo -e "  ${FAIL} Could not find client pod in ${BOLD}${CLIENT_NS}${RESET} with label ${BOLD}${CLIENT_LABEL}${RESET}"
  exit 1
fi
echo -e "  ${PASS} Client pod: ${BOLD}${PRODUCTPAGE_POD}${RESET}"

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
    echo -e "  ${PASS} DNS capture: ${GREEN}enabled${RESET}"
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

pause "Press ENTER to deploy legacy backend (TLS1.0 + legacy cipher)..."

header "Phase: Deploy legacy backend (simulated RHEL7 stack)"
section "2. Deploy legacy backend in namespace ${LEGACY_NS} (outside mesh)"

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

if ! oc --context "$CTX" rollout status deploy/${LEGACY_APP} -n "${LEGACY_NS}" --timeout=240s >/dev/null; then
  echo -e "  ${FAIL} Legacy backend did not become Ready in time."
  echo -e "  ${CYAN}Diagnostics:${RESET}"
  oc --context "$CTX" get pods -n "${LEGACY_NS}" -o wide || true
  LEGACY_POD=$(oc --context "$CTX" get pod -n "${LEGACY_NS}" -l app="${LEGACY_APP}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${LEGACY_POD}" ]]; then
    echo ""
    echo -e "  ${CYAN}Describe pod/${LEGACY_POD}:${RESET}"
    oc --context "$CTX" describe pod -n "${LEGACY_NS}" "${LEGACY_POD}" || true
    echo ""
    echo -e "  ${CYAN}Logs pod/${LEGACY_POD}:${RESET}"
    oc --context "$CTX" logs -n "${LEGACY_NS}" "${LEGACY_POD}" --tail=120 || true
  fi
  echo ""
  echo -e "  Tip: re-run with ${BOLD}KEEP_RESOURCES_ON_FAIL=true${RESET} to keep namespaces for inspection."
  exit 1
fi
LEGACY_SVC_IP=$(oc --context "$CTX" get svc/${LEGACY_SVC} -n "${LEGACY_NS}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
echo -e "  ${PASS} Legacy backend Service IP: ${BOLD}${LEGACY_SVC_IP}${RESET} (port ${LEGACY_PORT_TLS})"

pause "Press ENTER to configure ambient egress waypoint + ServiceEntries + TLS policies..."

header "Phase: Configure egress waypoint + TLS origination policies"
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
EGRESS_WP_POD=$(oc --context "$CTX" get pod -n "${EGRESS_NS}" -l gateway.networking.k8s.io/gateway-name="${WAYPOINT_NAME}" -o jsonpath='{.items[0].metadata.name}')
echo -e "  ${PASS} Egress waypoint pod: ${BOLD}${EGRESS_WP_POD}${RESET}"

section "3.1 Build HAProxy connector image (UBI7 + haproxy)"
build_haproxy_image
ensure_image_puller "${EGRESS_NS}"

section "4. Create ServiceEntry (front) to capture DNS"
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
  # The waypoint routes requests to internal connectors before any upstream resolution is needed.
  resolution: DNS
EOF

sleep 5
front_vip=$(oc --context "$CTX" get serviceentry legacy-front -n "${EGRESS_NS}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
front_bound=$(oc --context "$CTX" get serviceentry legacy-front -n "${EGRESS_NS}" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
echo -e "  ${PASS} ServiceEntry VIP (front): ${BOLD}${front_vip:-unknown}${RESET}, WaypointBound: ${BOLD}${front_bound:-unknown}${RESET}"

section "5. Deploy HAProxy connectors (modern vs compat)"
oc --context "$CTX" apply -f - <<EOF >/dev/null
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
      # strict: TLS >= 1.2 (will FAIL against TLS1.0 backend)
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
      # compat: TLS1.0 + legacy cipher
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
EOF

oc --context "$CTX" rollout status deploy/legacy-connector-modern -n "${EGRESS_NS}" --timeout=180s >/dev/null
oc --context "$CTX" rollout status deploy/legacy-connector-compat -n "${EGRESS_NS}" --timeout=180s >/dev/null

section "6. Apply VirtualService (header-based downgrade routing)"
oc --context "$CTX" apply -f - <<EOF >/dev/null
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

echo -e "  ${PASS} Egress routing + TLS policies applied"
echo -e "  Waiting 20s for propagation..."
sleep 20

pause "Press ENTER to run tests from the modern client (productpage)..."

header "Phase: Tests"

section "7. Test without downgrade header (expected FAIL)"
nohdr=$(run_client_http "" | tr -d '\r')
echo -e "  Result: ${BOLD}${nohdr}${RESET}"
if echo "$nohdr" | grep -q '^OK|200'; then
  echo -e "  ${WARN} Unexpected success (strict path should usually fail against TLS1.0-only backend)"
else
  echo -e "  ${PASS} Strict path failed as expected"
fi

section "8. Test WITH downgrade header (expected 200)"
withhdr=$(run_client_http "true" | tr -d '\r')
echo -e "  Result: ${BOLD}${withhdr}${RESET}"
if echo "$withhdr" | grep -q '^OK|200'; then
  echo -e "  ${PASS} Compat path succeeded (TLS origination to legacy backend works)"
  test_ok="pass"
else
  echo -e "  ${FAIL} Compat path did not succeed"
  test_ok="fail"
fi

section "9. Validate negotiated protocol/cipher in legacy backend logs"
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

if [[ "${KIALI_DEMO}" == "true" ]]; then
  header "Kiali demo mode enabled"
  section "Deploy background traffic (alternates strict vs compat)"
  deploy_kiali_traffic
  echo ""
  echo -e "  ${WARN} Resources are being kept for demo (KIALI_DEMO=true)."
  echo -e "  To cleanup later, run:"
  echo -e "    ${BOLD}KEEP_RESOURCES=false KIALI_DEMO=false ./ossm/uc11-verify.sh ${CTX}${RESET}"
  echo -e "  Or delete namespaces:"
  echo -e "    oc --context ${CTX} delete ns ${TRAFFIC_NS} ${EGRESS_NS} ${LEGACY_NS} --wait=false"
  exit 0
fi

trap - EXIT
cleanup

header "Results"
echo ""
echo -e "  | Check                               | Expected | Result |"
echo -e "  |-------------------------------------|----------|--------|"
printf   "  | Strict path (no header)             | FAIL     | %b |\n" \
  "$(! echo "$nohdr" | grep -q '^OK|200' && echo -e "${PASS}" || echo -e "${WARN}")"
printf   "  | Compat path (header downgrade=true) | 200 OK   | %b |\n" \
  "$([ "$test_ok" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf   "  | Legacy logs show TLSv1 + cipher     | present  | %b |\n" \
  "$([ "$test_cipher" = "pass" ] && echo -e "${PASS}" || echo -e "${WARN}")"
echo ""

if [[ "$test_ok" == "pass" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}${UC_ID} PASSED${RESET} — Legacy TLS origination with header-based downgrade works"
else
  echo -e "  ${FAIL} ${RED}${BOLD}${UC_ID} FAILED${RESET} — Compat path did not succeed"
fi
echo ""

