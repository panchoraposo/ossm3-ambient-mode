#!/bin/bash
#
# UC2-T2: ServiceAccount-Based Enablement — Verification Script
#

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

PASS="${GREEN}✔${RESET}"
FAIL="${RED}✘${RESET}"
WARN="${YELLOW}⚠${RESET}"

EAST_CTX="east2"
NS="bookinfo"
NS_EXT="bookinfo-external"
ERRORS=0

pause() {
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

cleanup() {
  oc --context "$EAST_CTX" delete authorizationpolicy reviews-deny-external -n "$NS" 2>/dev/null || true
  oc --context "$EAST_CTX" delete authorizationpolicy reviews-allow-by-identity -n "$NS" 2>/dev/null || true
  oc --context "$EAST_CTX" label svc reviews -n "$NS" istio.io/use-waypoint- 2>/dev/null || true
  oc --context "$EAST_CTX" delete gateway reviews-waypoint -n "$NS" 2>/dev/null || true
}
trap cleanup EXIT

check_page() {
  local label="$1"
  local url="$2"
  local expect_reviews_error="$3"

  local html http_code
  html=$(curl -s -m 20 --retry 2 --retry-delay 3 "${url}" 2>/dev/null)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "${url}" 2>/dev/null)

  echo -e "  ${label}: HTTP ${BOLD}${http_code}${RESET}"

  if [[ "$http_code" != "200" ]]; then
    echo -e "    ${FAIL} Expected HTTP 200"
    ERRORS=$((ERRORS + 1))
    return
  fi

  if echo "$html" | grep -q "Error fetching product details"; then
    echo -e "    ${FAIL} ${RED}Error fetching product details${RESET}"
    ERRORS=$((ERRORS + 1))
  else
    echo -e "    ${PASS} Book Details: ${GREEN}OK${RESET}"
  fi

  if echo "$html" | grep -q "Error fetching product reviews"; then
    if [[ "$expect_reviews_error" == "true" ]]; then
      echo -e "    ${PASS} Book Reviews: ${RED}${BOLD}DENIED${RESET} ${GREEN}(policy active — expected)${RESET}"
    else
      echo -e "    ${FAIL} Book Reviews: ${RED}Error${RESET} (unexpected)"
      ERRORS=$((ERRORS + 1))
    fi
  else
    if [[ "$expect_reviews_error" == "false" ]]; then
      echo -e "    ${PASS} Book Reviews: ${GREEN}OK${RESET}"
    else
      echo -e "    ${FAIL} Book Reviews: ${YELLOW}still working${RESET} (expected DENIED)"
      ERRORS=$((ERRORS + 1))
    fi
  fi
}

# ── Discover URLs ────────────────────────────────────────────────────────
EAST_HOST=$(oc --context "$EAST_CTX" get route bookinfo-gateway -n "$NS" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
EAST_URL="http://${EAST_HOST}/productpage"

EXT_HOST=$(oc --context "$EAST_CTX" get route bookinfo-external -n "$NS_EXT" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
EXTERNAL_URL="http://${EXT_HOST}/productpage"

# ── Banner ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  UC2-T2: ServiceAccount-Based Enablement                     ║${RESET}"
echo -e "${BOLD}║  Cross-Namespace Identity Authorization                      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# ── Phase 1: Verify bookinfo-external ────────────────────────────────────
header "1. Verify bookinfo-external namespace"

if ! oc --context "$EAST_CTX" get namespace "$NS_EXT" &>/dev/null; then
  echo ""
  echo -e "  ${WARN} Namespace ${BOLD}${NS_EXT}${RESET} does not exist — deploying now..."

  DOMAIN=$(oc --context "$EAST_CTX" get ingress.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}' 2>/dev/null)
  PP_IMAGE=$(oc --context "$EAST_CTX" get deployment productpage-v1 -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

  oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS_EXT}
  labels:
    istio.io/dataplane-mode: ambient
EOF
  oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bookinfo-external-productpage
  namespace: ${NS_EXT}
EOF
  oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: productpage
  namespace: ${NS_EXT}
  labels:
    app: productpage
spec:
  ports:
  - port: 9080
    name: http
    targetPort: 9080
  selector:
    app: productpage
EOF
  oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: productpage-v1
  namespace: ${NS_EXT}
  labels:
    app: productpage
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: productpage
      version: v1
  template:
    metadata:
      labels:
        app: productpage
        version: v1
    spec:
      serviceAccountName: bookinfo-external-productpage
      containers:
      - name: productpage
        image: "${PP_IMAGE}"
        ports:
        - containerPort: 9080
        env:
        - name: SERVICES_DOMAIN
          value: "bookinfo.svc.cluster.local"
        volumeMounts:
        - mountPath: /tmp
          name: tmp
      volumes:
      - emptyDir: {}
        name: tmp
EOF
  oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: bookinfo-external
  namespace: ${NS_EXT}
spec:
  host: "bookinfo-external.${DOMAIN}"
  to:
    kind: Service
    name: productpage
    weight: 100
  port:
    targetPort: 9080
  wildcardPolicy: None
EOF

  echo -e "  Waiting for productpage-v1 to be ready..."
  oc --context "$EAST_CTX" -n "$NS_EXT" rollout status deployment/productpage-v1 --timeout=120s &>/dev/null
  sleep 5

  EXT_HOST=$(oc --context "$EAST_CTX" get route bookinfo-external -n "$NS_EXT" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
  EXTERNAL_URL="http://${EXT_HOST}/productpage"
  echo -e "  ${PASS} ${BOLD}${NS_EXT}${RESET} deployed"
fi

ambient_label=$(oc --context "$EAST_CTX" get namespace "$NS_EXT" \
  -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null)
if [[ "$ambient_label" == "ambient" ]]; then
  echo -e "  ${PASS} Namespace ${BOLD}${NS_EXT}${RESET} — ambient mode: ${GREEN}enabled${RESET}"
else
  echo -e "  ${FAIL} Namespace ${BOLD}${NS_EXT}${RESET} — ambient mode: ${RED}not enabled${RESET}"
  exit 1
fi

section "productpage pod"
pp_status=$(oc --context "$EAST_CTX" get pods -n "$NS_EXT" -l app=productpage --no-headers 2>/dev/null)
if [[ -n "$pp_status" ]]; then
  pp_name=$(echo "$pp_status" | awk '{print $1}')
  pp_st=$(echo "$pp_status" | awk '{print $3}')
  echo -e "  ${PASS} ${pp_name}  ${GREEN}${pp_st}${RESET}"
else
  echo -e "  ${FAIL} productpage not found in ${NS_EXT}"
  exit 1
fi

section "SPIFFE identities"
echo -e "  ${CYAN}bookinfo${RESET}:          spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"
echo -e "  ${CYAN}bookinfo-external${RESET}: spiffe://cluster.local/ns/bookinfo-external/sa/bookinfo-external-productpage"

echo ""
echo -e "  Original URL:  ${CYAN}${EAST_URL}${RESET}"
echo -e "  External URL:  ${CYAN}${EXTERNAL_URL}${RESET}"

pause

# ── Phase 2: Baseline ────────────────────────────────────────────────────
header "2. Baseline — No AuthorizationPolicy"

section "Both should serve reviews normally"
check_page "Original (bookinfo)" "$EAST_URL" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_URL" "false"

pause "Press ENTER to deploy waypoint and DENY policy..."

# ── Phase 3: Waypoint + DENY ─────────────────────────────────────────────
header "3. Deploy waypoint & Apply DENY by namespace"

oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: reviews-waypoint
  namespace: ${NS}
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
EOF
echo -e "  ${PASS} Gateway ${GREEN}reviews-waypoint${RESET} created"

oc --context "$EAST_CTX" label svc reviews -n "$NS" \
  istio.io/use-waypoint=reviews-waypoint --overwrite 2>/dev/null
echo -e "  ${PASS} Service reviews labeled with ${GREEN}istio.io/use-waypoint${RESET}"

oc --context "$EAST_CTX" wait --for=condition=Ready \
  pod -l gateway.networking.k8s.io/gateway-name=reviews-waypoint \
  -n "$NS" --timeout=60s 2>/dev/null
echo -e "  ${PASS} Waypoint pod ${GREEN}Ready${RESET}"

oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: reviews-deny-external
  namespace: ${NS}
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: reviews
  action: DENY
  rules:
  - from:
    - source:
        namespaces:
        - ${NS_EXT}
EOF
echo -e "  ${PASS} AuthorizationPolicy ${RED}reviews-deny-external${RESET} applied"
echo -e "  Waiting for propagation..."
sleep 8

section "Original should work; external should be DENIED"
check_page "Original (bookinfo)" "$EAST_URL" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_URL" "true"

echo ""
echo -e "  ${CYAN}${BOLD}▶ Verify in browser:${RESET}"
echo -e "  ${CYAN}  Original:  ${EAST_URL}  → reviews work${RESET}"
echo -e "  ${CYAN}  External:  ${EXTERNAL_URL}  → reviews DENIED${RESET}"

pause "Press ENTER to switch to ALLOW by identity..."

# ── Phase 4: ALLOW by identity ───────────────────────────────────────────
header "4. Switch to ALLOW — Authorize both ServiceAccounts"

oc --context "$EAST_CTX" delete authorizationpolicy reviews-deny-external \
  -n "$NS" &>/dev/null

oc --context "$EAST_CTX" apply -f - <<EOF 2>/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: reviews-allow-by-identity
  namespace: ${NS}
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: reviews
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/bookinfo/sa/bookinfo-productpage"
        - "cluster.local/ns/bookinfo-external/sa/bookinfo-external-productpage"
EOF
echo -e "  ${PASS} AuthorizationPolicy ${GREEN}reviews-allow-by-identity${RESET} applied"
echo -e "  Waiting for propagation..."
sleep 8

section "Both should work now (both SAs authorized)"
check_page "Original (bookinfo)" "$EAST_URL" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_URL" "false"

echo ""
echo -e "  ${CYAN}${BOLD}▶ Verify in browser: both URLs now show reviews${RESET}"

pause "Press ENTER to cleanup..."

# ── Phase 5: Cleanup ─────────────────────────────────────────────────────
header "5. Cleanup"

oc --context "$EAST_CTX" delete authorizationpolicy reviews-allow-by-identity \
  -n "$NS" &>/dev/null
echo -e "  ${PASS} AuthorizationPolicy ${GREEN}removed${RESET}"
oc --context "$EAST_CTX" label svc reviews -n "$NS" istio.io/use-waypoint- 2>/dev/null
echo -e "  ${PASS} Waypoint label ${GREEN}removed${RESET}"
oc --context "$EAST_CTX" delete gateway reviews-waypoint -n "$NS" &>/dev/null
echo -e "  ${PASS} Waypoint gateway ${GREEN}deleted${RESET}"

sleep 5

section "Verify recovery"
check_page "Original (bookinfo)" "$EAST_URL" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_URL" "false"

# ── Summary ──────────────────────────────────────────────────────────────
header "SUMMARY"
echo ""
echo -e "  ${BOLD}Phase                  Original bookinfo    External bookinfo${RESET}"
echo -e "  No policy            ${GREEN}${BOLD}Reviews OK${RESET}            ${GREEN}${BOLD}Reviews OK${RESET}"
echo -e "  DENY by namespace    ${GREEN}${BOLD}Reviews OK${RESET}            ${RED}${BOLD}Reviews DENIED${RESET}"
echo -e "  ALLOW by identity    ${GREEN}${BOLD}Reviews OK${RESET}            ${GREEN}${BOLD}Reviews OK${RESET}"
echo -e "  After cleanup        ${GREEN}${BOLD}Reviews OK${RESET}            ${GREEN}${BOLD}Reviews OK${RESET}"
echo ""
echo -e "  ${BOLD}Why:${RESET} The mesh identifies each workload by its SPIFFE identity."
echo -e "  AuthorizationPolicies enforce access based on cryptographic identity —"
echo -e "  Zero Trust without application changes or pod restarts."
echo ""

if [[ "$ERRORS" -gt 0 ]]; then
  echo -e "  ${FAIL} ${RED}${ERRORS} error(s) detected${RESET}"
  exit 1
else
  echo -e "  ${PASS} ${GREEN}All checks passed${RESET}"
fi
echo ""
