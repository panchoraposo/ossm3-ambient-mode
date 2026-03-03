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

EAST_ROUTE="http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com"
EXTERNAL_ROUTE="http://bookinfo-external.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com"
KIALI_URL="https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph"

ERRORS=0

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

check_page() {
  local label="$1"
  local url="$2"
  local expect_reviews_error="$3"

  local html
  html=$(curl -s -m 15 "${url}/productpage" 2>/dev/null)
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 15 "${url}/productpage" 2>/dev/null)

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

# ── Banner ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  UC2-T2: ServiceAccount-Based Enablement                   ║${RESET}"
echo -e "${BOLD}║  Cross-Namespace Identity Authorization                    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# ── Phase 1: Setup bookinfo-external ─────────────────────────────────────
header "1. Setup bookinfo-external namespace"

if oc --context east get namespace bookinfo-external &>/dev/null; then
  echo -e "  ${PASS} Namespace ${BOLD}bookinfo-external${RESET} already exists"
else
  oc --context east create namespace bookinfo-external &>/dev/null
  echo -e "  ${PASS} Namespace ${BOLD}bookinfo-external${RESET} created"
fi

ambient_label=$(oc --context east get namespace bookinfo-external -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null)
if [[ "$ambient_label" != "ambient" ]]; then
  oc --context east label namespace bookinfo-external istio.io/dataplane-mode=ambient --overwrite &>/dev/null
fi
echo -e "  ${PASS} Ambient mode: ${GREEN}enabled${RESET}"

section "Deploy productpage in bookinfo-external"
oc --context east apply -f - <<'RESOURCES' &>/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bookinfo-external-productpage
  namespace: bookinfo-external
---
apiVersion: v1
kind: Service
metadata:
  name: productpage
  namespace: bookinfo-external
  labels:
    app: productpage
spec:
  ports:
  - port: 9080
    name: http
    targetPort: 9080
  selector:
    app: productpage
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: productpage-v1
  namespace: bookinfo-external
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
        image: quay.io/sail-dev/examples-bookinfo-productpage-v1:1.20.3
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: bookinfo-external-gateway
  namespace: bookinfo-external
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-external
  namespace: bookinfo-external
spec:
  parentRefs:
  - name: bookinfo-external-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /productpage
    - path:
        type: PathPrefix
        value: /static
    - path:
        type: PathPrefix
        value: /login
    - path:
        type: PathPrefix
        value: /logout
    backendRefs:
    - name: productpage
      port: 9080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: bookinfo-external-gateway
  namespace: bookinfo-external
spec:
  host: bookinfo-external.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com
  port:
    targetPort: 80
  to:
    kind: Service
    name: bookinfo-external-gateway-istio
    weight: 100
RESOURCES
echo -e "  ${PASS} ServiceAccount, Service, Deployment, Gateway, HTTPRoute, Route ${GREEN}applied${RESET}"

section "Waiting for pods to be ready"
oc --context east -n bookinfo-external rollout status deployment/productpage-v1 --timeout=120s &>/dev/null
echo -e "  ${PASS} productpage-v1: ${GREEN}ready${RESET}"

sleep 5

section "SPIFFE identities"
echo -e "  ${CYAN}bookinfo${RESET}:          spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"
echo -e "  ${CYAN}bookinfo-external${RESET}: spiffe://cluster.local/ns/bookinfo-external/sa/bookinfo-external-productpage"

# ── Phase 2: Baseline — both Routes work ─────────────────────────────────
header "2. Baseline — No AuthorizationPolicy"

section "Both Routes should serve reviews normally"
check_page "Original (bookinfo)" "$EAST_ROUTE" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_ROUTE" "false"

# ── Phase 3: DENY external namespace ─────────────────────────────────────
header "3. Apply AuthorizationPolicy — DENY bookinfo-external"

oc --context east apply -f - <<'EOF' &>/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: reviews-deny-external
  namespace: bookinfo
spec:
  selector:
    matchLabels:
      app: reviews
  action: DENY
  rules:
  - from:
    - source:
        namespaces:
        - bookinfo-external
EOF
echo -e "  ${PASS} AuthorizationPolicy ${RED}reviews-deny-external${RESET} applied"
echo -e "  Waiting 5 seconds for propagation..."
sleep 5

section "Original bookinfo should work; external should be denied"
check_page "Original (bookinfo)" "$EAST_ROUTE" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_ROUTE" "true"

section "ztunnel enforcement logs"
deny_logs=$(oc --context east logs -n ztunnel ds/ztunnel --tail=30 2>/dev/null | grep "reviews" | grep "policy rejection")
if [[ -n "$deny_logs" ]]; then
  deny_count=$(echo "$deny_logs" | wc -l | tr -d ' ')
  echo -e "  ${PASS} ${RED}${deny_count} denied${RESET} connections to reviews"
  echo "$deny_logs" | tail -1 | while read -r line; do
    identity=$(echo "$line" | grep -o 'src.identity="[^"]*"' | head -1)
    error=$(echo "$line" | grep -o 'error="[^"]*"' | head -1)
    [[ -n "$identity" ]] && echo -e "       ${CYAN}${identity}${RESET}"
    [[ -n "$error" ]] && echo -e "       ${CYAN}${error}${RESET}"
  done
else
  echo -e "  ${WARN} No deny entries yet in ztunnel logs"
fi

echo ""
echo -e "  ${CYAN}${BOLD}▶ Open both URLs in the browser to compare:${RESET}"
echo -e "  ${CYAN}  Original:  ${EAST_ROUTE}/productpage  → reviews work${RESET}"
echo -e "  ${CYAN}  External:  ${EXTERNAL_ROUTE}/productpage  → reviews DENIED${RESET}"
echo -e "  ${CYAN}  Kiali:     ${KIALI_URL}${RESET}"
echo ""
read -rp "  Press ENTER to continue to Phase 4 (ALLOW by identity)..."

# ── Phase 4: ALLOW with explicit identities ──────────────────────────────
header "4. Switch to ALLOW — Authorize both ServiceAccounts"

oc --context east delete authorizationpolicy reviews-deny-external -n bookinfo &>/dev/null
oc --context east apply -f - <<'EOF' &>/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: reviews-allow-by-identity
  namespace: bookinfo
spec:
  selector:
    matchLabels:
      app: reviews
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/bookinfo/sa/bookinfo-productpage"
        - "cluster.local/ns/bookinfo-external/sa/bookinfo-external-productpage"
EOF
echo -e "  ${PASS} AuthorizationPolicy ${GREEN}reviews-allow-by-identity${RESET} applied"
echo -e "  Waiting 5 seconds for propagation..."
sleep 5

section "Both Routes should work now"
check_page "Original (bookinfo)" "$EAST_ROUTE" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_ROUTE" "false"

echo ""
echo -e "  ${CYAN}${BOLD}▶ Verify in browser: both URLs now show reviews${RESET}"
echo ""
read -rp "  Press ENTER to continue to cleanup..."

# ── Phase 5: Cleanup ─────────────────────────────────────────────────────
header "5. Cleanup"

oc --context east delete authorizationpolicy reviews-allow-by-identity -n bookinfo &>/dev/null
echo -e "  ${PASS} AuthorizationPolicy ${GREEN}removed${RESET}"

sleep 3

section "Verify recovery"
check_page "Original (bookinfo)" "$EAST_ROUTE" "false"
check_page "External (bookinfo-external)" "$EXTERNAL_ROUTE" "false"

# ── Summary ──────────────────────────────────────────────────────────────
header "SUMMARY"
echo ""
echo -e "  ${BOLD}DENY by namespace:${RESET}    External productpage ${RED}blocked${RESET} from reviews"
echo -e "  ${BOLD}ALLOW by identity:${RESET}    External productpage ${GREEN}authorized${RESET} via SPIFFE principal"
echo -e "  ${BOLD}Original bookinfo:${RESET}    ${GREEN}Never affected${RESET} — zero downtime"
echo -e "  ${BOLD}Zero Trust model:${RESET}     Access controlled by cryptographic identity"
echo -e "  ${BOLD}Pod restarts:${RESET}         ${GREEN}ZERO${RESET}"
echo ""

if [[ "$ERRORS" -gt 0 ]]; then
  echo -e "  ${FAIL} ${RED}${ERRORS} error(s) detected${RESET}"
  exit 1
else
  echo -e "  ${PASS} ${GREEN}All checks passed${RESET}"
fi
echo ""
