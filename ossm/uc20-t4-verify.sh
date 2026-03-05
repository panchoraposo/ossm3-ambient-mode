#!/bin/bash
#
# UC20-T4: Request Authentication (JWT) — Verification Script
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

EAST_ROUTE="http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage"
KIALI_URL="https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph"
CTX="east"
NS="bookinfo"

JWKS_URI="https://raw.githubusercontent.com/istio/istio/release-1.27/security/tools/jwt/samples/jwks.json"
JWT_URL="https://raw.githubusercontent.com/istio/istio/release-1.27/security/tools/jwt/samples/demo.jwt"
ISSUER="testing@secure.istio.io"

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
  section "Cleanup: removing JWT policies"
  oc --context "$CTX" delete requestauthentication bookinfo-gateway-jwt -n "$NS" 2>/dev/null
  oc --context "$CTX" delete authorizationpolicy bookinfo-gateway-require-jwt -n "$NS" 2>/dev/null
  echo -e "  ${PASS} JWT policies removed"
}

# ── Phase 1: Baseline ───────────────────────────────────────────────
header "UC20-T4: Request Authentication (JWT)"

section "1. Baseline — unauthenticated traffic flows"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET} (no JWT required yet)"
else
  echo -e "  ${FAIL} EAST: ${RED}HTTP ${east_code}${RESET} — bookinfo not reachable, aborting"
  exit 1
fi

# ── Phase 2: Fetch test JWT ─────────────────────────────────────────
section "2. Fetch Istio test JWT"
TOKEN=$(curl -s --max-time 10 "$JWT_URL" 2>/dev/null)
if [[ -z "$TOKEN" || ${#TOKEN} -lt 100 ]]; then
  echo -e "  ${FAIL} Could not fetch test JWT from ${JWT_URL}"
  exit 1
fi
echo -e "  ${PASS} JWT fetched (${#TOKEN} chars)"

claims=$(echo "$TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null)
jwt_issuer=$(echo "$claims" | python3 -c "import sys,json; print(json.load(sys.stdin).get('iss',''))" 2>/dev/null)
jwt_sub=$(echo "$claims" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sub',''))" 2>/dev/null)
echo -e "  ${PASS} Issuer: ${BOLD}${jwt_issuer}${RESET}"
echo -e "  ${PASS} Subject: ${BOLD}${jwt_sub}${RESET}"

# ── Phase 3: Apply RequestAuthentication ────────────────────────────
section "3. Apply RequestAuthentication (JWT validation on ingress gateway)"
oc --context "$CTX" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: bookinfo-gateway-jwt
  namespace: $NS
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: bookinfo-gateway
  jwtRules:
  - issuer: "$ISSUER"
    jwksUri: "$JWKS_URI"
EOF
echo -e "  ${PASS} RequestAuthentication applied"

# ── Phase 4: Apply AuthorizationPolicy ──────────────────────────────
section "4. Apply AuthorizationPolicy (require valid JWT)"
oc --context "$CTX" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: bookinfo-gateway-require-jwt
  namespace: $NS
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: bookinfo-gateway
  rules:
  - from:
    - source:
        requestPrincipals: ["*"]
EOF
echo -e "  ${PASS} AuthorizationPolicy applied"

echo -e "  Waiting for policies to propagate..."
sleep 15

echo -e "  → Try: ${CYAN}curl -s -o /dev/null -w '%{http_code}' ${EAST_ROUTE}${RESET}"
read -rp "  ⏎ Press ENTER to test JWT enforcement..." _

# ── Phase 5: Test WITHOUT JWT → expect 403 ──────────────────────────
section "5. Test WITHOUT JWT — expect 403 (Forbidden)"
no_jwt_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$EAST_ROUTE" 2>/dev/null)
if [[ "$no_jwt_code" == "403" ]]; then
  echo -e "  ${PASS} ${GREEN}HTTP 403${RESET} — request without JWT correctly rejected"
  test_no_jwt="pass"
elif [[ "$no_jwt_code" == "401" ]]; then
  echo -e "  ${PASS} ${GREEN}HTTP 401${RESET} — request without JWT rejected (Unauthorized)"
  test_no_jwt="pass"
else
  echo -e "  ${FAIL} HTTP ${no_jwt_code} — expected 403 or 401"
  test_no_jwt="fail"
fi

# ── Phase 6: Test WITH valid JWT → expect 200 ───────────────────────
section "6. Test WITH valid JWT — expect 200"
valid_jwt_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
  -H "Authorization: Bearer $TOKEN" \
  "$EAST_ROUTE" 2>/dev/null)
if [[ "$valid_jwt_code" == "200" ]]; then
  echo -e "  ${PASS} ${GREEN}HTTP 200${RESET} — valid JWT accepted, productpage served"
  test_valid_jwt="pass"
else
  echo -e "  ${FAIL} HTTP ${valid_jwt_code} — expected 200"
  test_valid_jwt="fail"
fi

# ── Phase 7: Test WITH invalid JWT → expect 401 ─────────────────────
section "7. Test WITH invalid JWT — expect 401 (Unauthorized)"
invalid_jwt_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
  -H "Authorization: Bearer invalid.token.here" \
  "$EAST_ROUTE" 2>/dev/null)
if [[ "$invalid_jwt_code" == "401" ]]; then
  echo -e "  ${PASS} ${GREEN}HTTP 401${RESET} — invalid JWT correctly rejected"
  test_invalid_jwt="pass"
else
  echo -e "  ${FAIL} HTTP ${invalid_jwt_code} — expected 401"
  test_invalid_jwt="fail"
fi

echo ""
echo -e "  → Refresh browser: ${BOLD}${EAST_ROUTE}${RESET} (should show 'RBAC: access denied')"
echo -e "  → Try with JWT:  ${CYAN}TOKEN=\$(curl -s ${JWT_URL})${RESET}"
echo -e "                    ${CYAN}curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$TOKEN\" ${EAST_ROUTE}${RESET}"
echo -e "  → Kiali: ${BOLD}${KIALI_URL}${RESET}"
read -rp "  ⏎ Press ENTER to see results and cleanup..." _

# ── Results ─────────────────────────────────────────────────────────
header "Results"
echo ""

all_pass="true"
[[ "$test_no_jwt" != "pass" ]] && all_pass="false"
[[ "$test_valid_jwt" != "pass" ]] && all_pass="false"
[[ "$test_invalid_jwt" != "pass" ]] && all_pass="false"

echo -e "  | Test                | Expected | Got  | Result |"
echo -e "  |---------------------|----------|------|--------|"
printf "  | No JWT              | 403      | %-4s | %b |\n" \
  "$no_jwt_code" "$([ "$test_no_jwt" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | Valid JWT           | 200      | %-4s | %b |\n" \
  "$valid_jwt_code" "$([ "$test_valid_jwt" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | Invalid JWT         | 401      | %-4s | %b |\n" \
  "$invalid_jwt_code" "$([ "$test_invalid_jwt" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
echo ""

if [[ "$all_pass" == "true" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC20-T4 PASSED${RESET} — JWT authentication works at the ingress gateway"
  echo -e "     RequestAuthentication validates JWT issuer and signature"
  echo -e "     AuthorizationPolicy enforces mandatory token requirement"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC20-T4 FAILED${RESET} — some tests did not pass"
fi

# ── Cleanup & recovery ──────────────────────────────────────────────
cleanup
trap - EXIT

sleep 5
section "8. Verify recovery after cleanup"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET} — normal operation restored (no JWT required)"
else
  echo -e "  ${WARN} EAST: HTTP ${east_code} — may need a moment to recover"
fi
echo ""
