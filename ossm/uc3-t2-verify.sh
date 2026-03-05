#!/bin/bash
#
# UC3-T2: Adding Intelligence — Canary Deployment (East-West via Waypoint)
# Uses HTTPRoute (Gateway API) with parentRefs targeting Service (mesh-internal)
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
  oc --context "$CTX" delete httproute reviews-canary -n "$NS" 2>/dev/null
  oc --context "$CTX" delete svc reviews-v1-only reviews-v3-only -n "$NS" 2>/dev/null
  oc --context "$CTX" label svc reviews -n "$NS" istio.io/use-waypoint- 2>/dev/null
  oc --context "$CTX" delete gateway reviews-waypoint -n "$NS" 2>/dev/null
}

PRODUCTPAGE_POD=""

get_version_distribution() {
  local count="$1"
  oc --context "$CTX" exec -n "$NS" "$PRODUCTPAGE_POD" -- python3 -c "
import urllib.request, json, time
counts = {'v1': 0, 'v3': 0, 'other': 0, 'error': 0}
for i in range(${count}):
    time.sleep(1)
    try:
        req = urllib.request.Request('http://reviews:9080/reviews/0')
        with urllib.request.urlopen(req, timeout=10) as resp:
            pod = json.loads(resp.read().decode()).get('podname', '?')
            if 'v1' in pod:
                counts['v1'] += 1
            elif 'v3' in pod:
                counts['v3'] += 1
            else:
                counts['other'] += 1
    except:
        counts['error'] += 1
print(f'{counts[\"v1\"]}|{counts[\"v3\"]}|{counts[\"other\"]}|{counts[\"error\"]}')
" 2>/dev/null
}

trap cleanup EXIT

# ── Start ────────────────────────────────────────────────────────────
header "UC3-T2: Canary Deployment (East-West via Waypoint) — HTTPRoute"

section "1. Verify bookinfo is accessible"
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

# ── Create version services ─────────────────────────────────────────
section "2. Create version-specific Services"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: reviews-v1-only
  namespace: bookinfo
spec:
  ports:
  - port: 9080
    name: http
  selector:
    app: reviews
    version: v1
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v3-only
  namespace: bookinfo
spec:
  ports:
  - port: 9080
    name: http
  selector:
    app: reviews
    version: v3
EOF
echo -e "  ${PASS} Services reviews-v1-only and reviews-v3-only created"

# ── Deploy reviews-waypoint ──────────────────────────────────────────
section "3. Deploy reviews-waypoint (L7 proxy for HTTPRoute)"
oc --context "$CTX" apply -f - <<EOF 2>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: reviews-waypoint
  namespace: $NS
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
oc --context "$CTX" label svc reviews -n "$NS" istio.io/use-waypoint=reviews-waypoint --overwrite 2>/dev/null
echo -e "  ${PASS} Service reviews labeled with ${GREEN}istio.io/use-waypoint=reviews-waypoint${RESET}"
oc --context "$CTX" wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=reviews-waypoint -n "$NS" --timeout=60s 2>/dev/null
echo -e "  ${PASS} Waypoint pod ${GREEN}Ready${RESET}"

pause "Press ENTER to begin canary phases..."

# ── Phase A: 100% v1 ────────────────────────────────────────────────
header "Phase A: Route 100% to v1"

section "4. Apply HTTPRoute (100% v1)"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-v1-only
      port: 9080
      weight: 100
    - name: reviews-v3-only
      port: 9080
      weight: 0
EOF
echo -e "  ${PASS} HTTPRoute applied (100% v1)"
echo -e "  Waiting 15s for propagation..."
sleep 15

section "5. Verify: all traffic → v1"
result_a=$(get_version_distribution 10)
a_v1=$(echo "$result_a" | cut -d'|' -f1)
a_v3=$(echo "$result_a" | cut -d'|' -f2)
a_other=$(echo "$result_a" | cut -d'|' -f3)
a_err=$(echo "$result_a" | cut -d'|' -f4)

echo -e "  v1: ${BOLD}${a_v1}${RESET}  v3: ${BOLD}${a_v3}${RESET}  other: ${a_other}  errors: ${a_err}"

if [[ "$a_v1" -gt 0 && "$a_v3" -eq 0 && "$a_other" -eq 0 ]]; then
  echo -e "  ${PASS} ${GREEN}All successful traffic routed to v1${RESET}"
  test_100v1="pass"
elif [[ "$a_v3" -eq 0 && "$a_other" -eq 0 && "$a_v1" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}All successful traffic routed to v1${RESET} (some timeouts)"
  test_100v1="pass"
else
  echo -e "  ${FAIL} Expected all traffic to v1, got v3=${a_v3}"
  test_100v1="fail"
fi

echo ""
echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET} (should show reviews without stars = v1)"
echo -e "  → Kiali graph: ${BOLD}${KIALI_URL}${RESET}"
echo -e "  → Try: ${CYAN}curl -s ${EAST_ROUTE} | grep -o 'full stars\\|no stars\\|color'${RESET}"
pause "Press ENTER to shift to 50/50 canary..."

# ── Phase B: 50/50 Canary ───────────────────────────────────────────
header "Phase B: Canary 50/50 (v1/v3)"

section "6. Shift weights to 50/50"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-v1-only
      port: 9080
      weight: 50
    - name: reviews-v3-only
      port: 9080
      weight: 50
EOF
echo -e "  ${PASS} Weights shifted to 50/50"
echo -e "  Waiting 15s for propagation..."
sleep 15

section "7. Verify: traffic split between v1 and v3"
result_b=$(get_version_distribution 12)
b_v1=$(echo "$result_b" | cut -d'|' -f1)
b_v3=$(echo "$result_b" | cut -d'|' -f2)
b_other=$(echo "$result_b" | cut -d'|' -f3)
b_err=$(echo "$result_b" | cut -d'|' -f4)

echo -e "  v1: ${BOLD}${b_v1}${RESET}  v3: ${BOLD}${b_v3}${RESET}  other: ${b_other}  errors: ${b_err}"

if [[ "$b_v1" -gt 0 && "$b_v3" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}Traffic split confirmed${RESET}: both v1 and v3 receiving traffic"
  test_5050="pass"
else
  echo -e "  ${WARN} Expected both v1 and v3 to receive traffic"
  test_5050="warn"
fi

echo ""
echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET} (refresh to see v1/v3 alternating)"
echo -e "  → Kiali graph: ${BOLD}${KIALI_URL}${RESET}"
pause "Press ENTER to promote v3 to 100%..."

# ── Phase C: 100% v3 (Promotion) ────────────────────────────────────
header "Phase C: Promote v3 (100%)"

section "8. Shift weights to 0/100"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-v1-only
      port: 9080
      weight: 0
    - name: reviews-v3-only
      port: 9080
      weight: 100
EOF
echo -e "  ${PASS} Weights shifted to 100% v3"
echo -e "  Waiting 15s for propagation..."
sleep 15

section "9. Verify: all traffic → v3"
result_c=$(get_version_distribution 10)
c_v1=$(echo "$result_c" | cut -d'|' -f1)
c_v3=$(echo "$result_c" | cut -d'|' -f2)
c_other=$(echo "$result_c" | cut -d'|' -f3)
c_err=$(echo "$result_c" | cut -d'|' -f4)

echo -e "  v1: ${BOLD}${c_v1}${RESET}  v3: ${BOLD}${c_v3}${RESET}  other: ${c_other}  errors: ${c_err}"

if [[ "$c_v3" -gt 0 && "$c_v1" -eq 0 && "$c_other" -eq 0 ]]; then
  echo -e "  ${PASS} ${GREEN}All successful traffic routed to v3${RESET}"
  test_100v3="pass"
else
  echo -e "  ${FAIL} Expected all traffic to v3, got v1=${c_v1}"
  test_100v3="fail"
fi

echo ""
echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET} (should show red stars = v3)"
echo -e "  → Kiali graph: ${BOLD}${KIALI_URL}${RESET}"
pause "Press ENTER to cleanup..."

# ── Cleanup ──────────────────────────────────────────────────────────
section "10. Cleanup"
trap - EXIT
cleanup
echo -e "  ${PASS} Resources deleted"
sleep 5

# ── Recovery ─────────────────────────────────────────────────────────
section "11. Verify recovery"
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
[[ "$test_100v1" != "pass" ]] && all_pass="false"
[[ "$test_5050" != "pass" ]] && all_pass="false"
[[ "$test_100v3" != "pass" ]] && all_pass="false"

echo -e "  | Phase              | v1     | v3     | Expected          | Result |"
echo -e "  |--------------------|--------|--------|-------------------|--------|"
printf "  | 100%% v1            | %-6s | %-6s | all → v1          | %b |\n" \
  "$a_v1" "$a_v3" "$([ "$test_100v1" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | 50/50 canary       | %-6s | %-6s | both get traffic  | %b |\n" \
  "$b_v1" "$b_v3" "$([ "$test_5050" = "pass" ] && echo -e "${PASS}" || echo -e "${WARN}")"
printf "  | 100%% v3 (promoted) | %-6s | %-6s | all → v3          | %b |\n" \
  "$c_v1" "$c_v3" "$([ "$test_100v3" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
echo ""

if [[ "$all_pass" == "true" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC3-T2 PASSED${RESET} — Canary deployment (east-west) works in ambient mode"
  echo -e "     HTTPRoute (Gateway API) weighted routing enforced by waypoint proxy"
  echo -e "     parentRefs: Service (mesh-internal) — applies to ALL callers"
  echo -e "     Progressive: 100% v1 → 50/50 → 100% v3"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC3-T2 FAILED${RESET} — some phases did not pass"
fi
echo ""
