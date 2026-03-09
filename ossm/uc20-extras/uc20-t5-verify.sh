#!/bin/bash
#
# UC20-T5: Egress Control — Verification Script
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

pause() {
  echo ""
  echo -e "  ${CYAN}╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶${RESET}"
  read -rp "  ⏎ ${1:-Press ENTER to continue...} " _
}

EAST_ROUTE="http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage"
KIALI_URL="https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph"
CTX="east"
NS="bookinfo"
EGRESS_NS="egress-control"

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
  oc --context "$CTX" delete authorizationpolicy httpbin-egress-policy -n "$EGRESS_NS" 2>/dev/null
  oc --context "$CTX" delete serviceentry httpbin-org -n "$EGRESS_NS" 2>/dev/null
  istioctl --context "$CTX" waypoint delete --namespace "$EGRESS_NS" egress-gateway 2>/dev/null
  oc --context "$CTX" label namespace "$EGRESS_NS" istio.io/dataplane-mode- 2>/dev/null
  oc --context "$CTX" label namespace "$EGRESS_NS" istio.io/use-waypoint- 2>/dev/null
  oc --context "$CTX" delete namespace "$EGRESS_NS" 2>/dev/null
}

http_call() {
  local url="$1"
  local method="${2:-GET}"
  oc --context "$CTX" exec -n "$NS" "$PRODUCTPAGE_POD" -- python3 -c "
import urllib.request
try:
    data = b'test' if '${method}' == 'POST' else None
    req = urllib.request.Request('${url}', data=data, method='${method}')
    with urllib.request.urlopen(req, timeout=10) as resp:
        server = resp.headers.get('server', 'unknown')
        envoy_time = resp.headers.get('x-envoy-upstream-service-time', 'none')
        print(f'{resp.status}|{server}|{envoy_time}')
except urllib.error.HTTPError as e:
    body = e.read().decode()[:50]
    print(f'{e.code}|error|{body}')
except Exception as e:
    print(f'0|error|{e}')
" 2>/dev/null
}

trap cleanup EXIT

# ── Start ────────────────────────────────────────────────────────────
header "UC20-T5: Egress Control"

section "1. Verify bookinfo and prerequisites"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET}"
else
  echo -e "  ${FAIL} EAST: ${RED}HTTP ${east_code}${RESET} — aborting"
  exit 1
fi

PRODUCTPAGE_POD=$(oc --context "$CTX" get pods -n "$NS" -l app=productpage \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo -e "  ${PASS} productpage pod: ${BOLD}${PRODUCTPAGE_POD}${RESET}"

dns_capture=$(oc --context "$CTX" get istiocni default \
  -o jsonpath='{.spec.values.cni.ambient.dnsCapture}' 2>/dev/null)
if [[ "$dns_capture" == "true" ]]; then
  echo -e "  ${PASS} DNS capture: ${GREEN}enabled${RESET}"
else
  echo -e "  ${FAIL} DNS capture: ${RED}disabled${RESET} — enable with:"
  echo -e "     oc --context $CTX patch istiocni default --type merge -p '{\"spec\":{\"values\":{\"cni\":{\"ambient\":{\"dnsCapture\":true}}}}}'"
  echo -e "     Then restart istio-cni-node, ztunnel, and bookinfo pods"
  exit 1
fi

# ── Baseline ─────────────────────────────────────────────────────────
section "2. Baseline — external access without egress control"
baseline=$(http_call "http://httpbin.org/get")
bl_status=$(echo "$baseline" | cut -d'|' -f1)
bl_server=$(echo "$baseline" | cut -d'|' -f2)
if [[ "$bl_status" == "200" ]]; then
  echo -e "  ${PASS} GET httpbin.org/get: ${GREEN}${bl_status}${RESET} (Server: ${bl_server})"
else
  echo -e "  ${FAIL} GET httpbin.org/get: ${RED}${bl_status}${RESET} — cannot reach external service"
  exit 1
fi

pause "Press ENTER to configure egress gateway..."

# ── Setup egress gateway ─────────────────────────────────────────────
header "Phase: Configure Egress Gateway"

section "3. Create egress namespace with waypoint"
oc --context "$CTX" create namespace "$EGRESS_NS" 2>/dev/null
oc --context "$CTX" label namespace "$EGRESS_NS" istio.io/dataplane-mode=ambient 2>/dev/null
istioctl --context "$CTX" waypoint apply --enroll-namespace \
  --name egress-gateway --namespace "$EGRESS_NS" 2>&1
sleep 10

gw_pod=$(oc --context "$CTX" get pods -n "$EGRESS_NS" \
  -l gateway.networking.k8s.io/gateway-name=egress-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$gw_pod" ]]; then
  echo -e "  ${PASS} egress-gateway pod: ${BOLD}${gw_pod}${RESET}"
else
  echo -e "  ${FAIL} egress-gateway pod not found — aborting"
  exit 1
fi

section "4. Create ServiceEntry for httpbin.org"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin-org
  namespace: egress-control
spec:
  hosts:
  - httpbin.org
  ports:
  - number: 80
    name: http
    protocol: HTTP
  resolution: DNS
EOF
echo -e "  ${PASS} ServiceEntry applied"
sleep 10

waypoint_bound=$(oc --context "$CTX" get serviceentry httpbin-org -n "$EGRESS_NS" \
  -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)
se_vip=$(oc --context "$CTX" get serviceentry httpbin-org -n "$EGRESS_NS" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
echo -e "  ${PASS} VIP: ${BOLD}${se_vip}${RESET}, WaypointBound: ${BOLD}${waypoint_bound}${RESET}"

# ── Test via egress gateway ──────────────────────────────────────────
section "5. Verify traffic goes through egress gateway"
egress_result=$(http_call "http://httpbin.org/get")
eg_status=$(echo "$egress_result" | cut -d'|' -f1)
eg_server=$(echo "$egress_result" | cut -d'|' -f2)
eg_envoy=$(echo "$egress_result" | cut -d'|' -f3)

if [[ "$eg_status" == "200" && "$eg_server" == "istio-envoy" ]]; then
  echo -e "  ${PASS} Status: ${GREEN}${eg_status}${RESET}, Server: ${BOLD}${eg_server}${RESET}, Envoy time: ${eg_envoy}ms"
  test_egress="pass"
elif [[ "$eg_status" == "200" ]]; then
  echo -e "  ${WARN} Status: ${eg_status} but Server: ${eg_server} (not through egress gateway)"
  test_egress="warn"
else
  echo -e "  ${FAIL} Status: ${RED}${eg_status}${RESET}"
  test_egress="fail"
fi

pause "Press ENTER to apply egress AuthorizationPolicy..."

# ── AuthorizationPolicy ─────────────────────────────────────────────
header "Phase: Enforce Egress Policy"

section "6. Apply AuthorizationPolicy — allow only GET /get"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-egress-policy
  namespace: egress-control
spec:
  targetRefs:
  - kind: ServiceEntry
    group: networking.istio.io
    name: httpbin-org
  action: ALLOW
  rules:
  - to:
    - operation:
        methods: ["GET"]
        paths: ["/get"]
EOF
echo -e "  ${PASS} AuthorizationPolicy applied"
echo -e "  Waiting 15s for propagation..."
sleep 15

section "7. Test access control"

# Test 1: GET /get — should be ALLOWED
t1=$(http_call "http://httpbin.org/get")
t1_status=$(echo "$t1" | cut -d'|' -f1)
if [[ "$t1_status" == "200" ]]; then
  echo -e "  ${PASS} GET /get:     ${GREEN}${t1_status}${RESET} — allowed"
  test_allow="pass"
else
  echo -e "  ${FAIL} GET /get:     ${RED}${t1_status}${RESET} — expected 200"
  test_allow="fail"
fi

# Test 2: GET /headers — should be DENIED
t2=$(http_call "http://httpbin.org/headers")
t2_status=$(echo "$t2" | cut -d'|' -f1)
if [[ "$t2_status" == "403" ]]; then
  echo -e "  ${PASS} GET /headers: ${GREEN}${t2_status}${RESET} — RBAC denied"
  test_deny_path="pass"
else
  echo -e "  ${FAIL} GET /headers: ${RED}${t2_status}${RESET} — expected 403"
  test_deny_path="fail"
fi

# Test 3: POST /post — should be DENIED
t3=$(http_call "http://httpbin.org/post" "POST")
t3_status=$(echo "$t3" | cut -d'|' -f1)
if [[ "$t3_status" == "403" ]]; then
  echo -e "  ${PASS} POST /post:   ${GREEN}${t3_status}${RESET} — RBAC denied"
  test_deny_method="pass"
else
  echo -e "  ${FAIL} POST /post:   ${RED}${t3_status}${RESET} — expected 403"
  test_deny_method="fail"
fi

echo ""
echo -e "  → Kiali: ${BOLD}${KIALI_URL}${RESET} (check egress-control namespace)"
pause "Press ENTER to cleanup..."

# ── Cleanup ──────────────────────────────────────────────────────────
section "8. Cleanup"
trap - EXIT
cleanup
echo -e "  ${PASS} Egress resources deleted"
sleep 5

# ── Recovery ─────────────────────────────────────────────────────────
section "9. Verify recovery"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET} — normal operation restored"
else
  echo -e "  ${WARN} EAST: HTTP ${east_code} — may need a moment to recover"
fi

# ── Results ──────────────────────────────────────────────────────────
header "Results"
echo ""

all_pass="true"
[[ "$test_egress" != "pass" ]] && all_pass="false"
[[ "$test_allow" != "pass" ]] && all_pass="false"
[[ "$test_deny_path" != "pass" ]] && all_pass="false"
[[ "$test_deny_method" != "pass" ]] && all_pass="false"

echo -e "  | Test                        | Expected       | Got  | Result |"
echo -e "  |-----------------------------|----------------|------|--------|"
printf "  | Egress gateway routing      | istio-envoy    | %s | %b |\n" \
  "$eg_server" "$([ "$test_egress" = "pass" ] && echo -e "${PASS}" || echo -e "${WARN}")"
printf "  | GET /get (allowed)          | 200            | %s  | %b |\n" \
  "$t1_status" "$([ "$test_allow" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | GET /headers (denied path)  | 403            | %s  | %b |\n" \
  "$t2_status" "$([ "$test_deny_path" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | POST /post (denied method)  | 403            | %s  | %b |\n" \
  "$t3_status" "$([ "$test_deny_method" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
echo ""

if [[ "$all_pass" == "true" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC20-T5 PASSED${RESET} — Egress control works in ambient mode"
  echo -e "     DNS capture: ztunnel resolves httpbin.org to VIP ${se_vip}"
  echo -e "     Egress gateway: waypoint processes all external traffic"
  echo -e "     AuthorizationPolicy: only GET /get allowed, everything else denied"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC20-T5 FAILED${RESET} — some tests did not pass"
fi
echo ""
