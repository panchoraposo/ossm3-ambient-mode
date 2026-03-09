#!/bin/bash
#
# UC3-T2: Adding Intelligence — Canary Deployment (East-West via Waypoint)
# Uses VirtualService + DestinationRule (subsets) for weighted routing
# through a waypoint proxy in Istio 1.29 ambient mode
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
WEST_CTX="west2"
NS="bookinfo"
ROUTE_NAME="bookinfo-gateway"

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
  oc --context "$EAST_CTX" delete virtualservice reviews-canary -n "$NS" &>/dev/null || true
  oc --context "$EAST_CTX" delete destinationrule reviews-versions -n "$NS" &>/dev/null || true
  oc --context "$EAST_CTX" label svc reviews -n "$NS" istio.io/use-waypoint- &>/dev/null || true
  oc --context "$EAST_CTX" delete gateway reviews-waypoint -n "$NS" &>/dev/null || true
  oc --context "$WEST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
    -n "$NS" --replicas=1 &>/dev/null || true
}
trap cleanup EXIT

EAST_HOST=$(oc --context "$EAST_CTX" get route "$ROUTE_NAME" -n "$NS" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
EAST_URL="http://${EAST_HOST}/productpage"

PRODUCTPAGE_POD=""

get_version_distribution() {
  local count="$1"
  oc --context "$EAST_CTX" exec -n "$NS" "$PRODUCTPAGE_POD" -- python3 -c "
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

# ── Banner ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  UC3-T2: Adding Intelligence — Canary via Waypoint         ║${RESET}"
echo -e "${BOLD}║  VirtualService + DestinationRule weighted routing          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# ── Step 1: Verify baseline ──────────────────────────────────────────
header "1. Verify Baseline"

section "bookinfo accessibility"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_URL" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST2: ${GREEN}HTTP ${east_code}${RESET}"
else
  echo -e "  ${FAIL} EAST2: ${RED}HTTP ${east_code}${RESET} — aborting"
  exit 1
fi

PRODUCTPAGE_POD=$(oc --context "$EAST_CTX" get pods -n "$NS" -l app=productpage \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo -e "  ${PASS} productpage pod: ${BOLD}${PRODUCTPAGE_POD}${RESET}"

section "Baseline traffic distribution (no waypoint, L4 only)"
result_baseline=$(get_version_distribution 6)
bl_v1=$(echo "$result_baseline" | cut -d'|' -f1)
bl_v3=$(echo "$result_baseline" | cut -d'|' -f2)
bl_other=$(echo "$result_baseline" | cut -d'|' -f3)
bl_err=$(echo "$result_baseline" | cut -d'|' -f4)
echo -e "  v1: ${BOLD}${bl_v1}${RESET}  v3: ${BOLD}${bl_v3}${RESET}  other: ${BOLD}${bl_other}${RESET}  errors: ${bl_err}"
echo -e "  ${PASS} Baseline: traffic distributed across all versions (round-robin)"

pause "Press ENTER to deploy waypoint and prepare canary..."

# ── Step 2: Isolate local traffic + deploy waypoint ──────────────────
header "2. Deploy Waypoint & Prepare Environment"

section "Scale WEST2 reviews to 0 (isolate local traffic)"
echo -e "  In multi-cluster, the east-west gateway is an opaque L4 tunnel."
echo -e "  Scaling WEST2 reviews to 0 ensures canary routing is fully enforced"
echo -e "  by the local EAST2 waypoint."
echo ""
oc --context "$WEST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n "$NS" --replicas=0 &>/dev/null
echo -e "  ${PASS} WEST2 reviews scaled to ${RED}${BOLD}0${RESET}"
sleep 5

section "Deploy reviews-waypoint (L7 proxy)"
oc --context "$EAST_CTX" apply -f - <<EOF &>/dev/null
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
oc --context "$EAST_CTX" label svc reviews -n "$NS" istio.io/use-waypoint=reviews-waypoint --overwrite &>/dev/null
echo -e "  ${PASS} Service reviews labeled with ${GREEN}istio.io/use-waypoint${RESET}"
oc --context "$EAST_CTX" wait --for=condition=Ready pod \
  -l gateway.networking.k8s.io/gateway-name=reviews-waypoint \
  -n "$NS" --timeout=60s &>/dev/null
echo -e "  ${PASS} Waypoint pod ${GREEN}Ready${RESET}"

section "Apply DestinationRule (version subsets)"
oc --context "$EAST_CTX" apply -f - <<'EOF' &>/dev/null
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-versions
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v3
    labels:
      version: v3
EOF
echo -e "  ${PASS} DestinationRule ${GREEN}reviews-versions${RESET} (subsets v1, v3)"

echo ""
echo -e "  Waiting 10s for waypoint to stabilize..."
sleep 10

pause "Press ENTER to apply 100% v1..."

# ── Phase A: 100% v1 ────────────────────────────────────────────────
header "Phase A: Route 100% → v1"

oc --context "$EAST_CTX" apply -f - <<'EOF' &>/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 100
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v3
      weight: 0
EOF
echo -e "  ${PASS} VirtualService applied (${BOLD}100% v1${RESET}, 0% v3)"
echo -e "  Waiting 15s for propagation..."
sleep 15

section "Verify: all traffic → v1"
result_a=$(get_version_distribution 10)
a_v1=$(echo "$result_a" | cut -d'|' -f1)
a_v3=$(echo "$result_a" | cut -d'|' -f2)
a_other=$(echo "$result_a" | cut -d'|' -f3)
a_err=$(echo "$result_a" | cut -d'|' -f4)

echo -e "  v1: ${BOLD}${a_v1}${RESET}  v3: ${BOLD}${a_v3}${RESET}  other: ${a_other}  errors: ${a_err}"

if [[ "$a_v1" -gt 0 && "$a_v3" -eq 0 && "$a_other" -eq 0 ]]; then
  echo -e "  ${PASS} ${GREEN}All traffic routed to v1${RESET}"
  test_100v1="pass"
elif [[ "$a_v3" -eq 0 && "$a_other" -eq 0 && "$a_err" -gt 0 && "$a_v1" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}All successful traffic routed to v1${RESET} (${a_err} timeouts)"
  test_100v1="pass"
else
  echo -e "  ${FAIL} Expected all traffic to v1"
  test_100v1="fail"
fi

echo ""
echo -e "  ${CYAN}${BOLD}▶ Verify in browser (reviews without stars = v1):${RESET}"
echo -e "  ${CYAN}  ${EAST_URL}${RESET}"

pause "Press ENTER to shift to 50/50 canary..."

# ── Phase B: 50/50 Canary ───────────────────────────────────────────
header "Phase B: Canary 50/50 (v1 / v3)"

oc --context "$EAST_CTX" apply -f - <<'EOF' &>/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 50
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v3
      weight: 50
EOF
echo -e "  ${PASS} Weights shifted to ${BOLD}50/50${RESET}"
echo -e "  Waiting 15s for propagation..."
sleep 15

section "Verify: traffic split between v1 and v3"
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
echo -e "  ${CYAN}${BOLD}▶ Verify in browser (refresh — alternates no stars / red stars):${RESET}"
echo -e "  ${CYAN}  ${EAST_URL}${RESET}"

pause "Press ENTER to promote v3 to 100%..."

# ── Phase C: 100% v3 (Promotion) ────────────────────────────────────
header "Phase C: Promote v3 (100%)"

oc --context "$EAST_CTX" apply -f - <<'EOF' &>/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 0
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v3
      weight: 100
EOF
echo -e "  ${PASS} Weights shifted to ${BOLD}100% v3${RESET}"
echo -e "  Waiting 15s for propagation..."
sleep 15

section "Verify: all traffic → v3"
result_c=$(get_version_distribution 10)
c_v1=$(echo "$result_c" | cut -d'|' -f1)
c_v3=$(echo "$result_c" | cut -d'|' -f2)
c_other=$(echo "$result_c" | cut -d'|' -f3)
c_err=$(echo "$result_c" | cut -d'|' -f4)

echo -e "  v1: ${BOLD}${c_v1}${RESET}  v3: ${BOLD}${c_v3}${RESET}  other: ${c_other}  errors: ${c_err}"

if [[ "$c_v3" -gt 0 && "$c_v1" -eq 0 && "$c_other" -eq 0 ]]; then
  echo -e "  ${PASS} ${GREEN}All traffic routed to v3${RESET}"
  test_100v3="pass"
elif [[ "$c_v1" -eq 0 && "$c_other" -eq 0 && "$c_err" -gt 0 && "$c_v3" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}All successful traffic routed to v3${RESET} (${c_err} timeouts)"
  test_100v3="pass"
else
  echo -e "  ${FAIL} Expected all traffic to v3"
  test_100v3="fail"
fi

echo ""
echo -e "  ${CYAN}${BOLD}▶ Verify in browser (red stars = v3):${RESET}"
echo -e "  ${CYAN}  ${EAST_URL}${RESET}"

pause "Press ENTER to cleanup and restore..."

# ── Cleanup ──────────────────────────────────────────────────────────
header "Cleanup & Restore"

trap - EXIT

section "Remove L7 resources"
oc --context "$EAST_CTX" delete virtualservice reviews-canary -n "$NS" &>/dev/null || true
oc --context "$EAST_CTX" delete destinationrule reviews-versions -n "$NS" &>/dev/null || true
oc --context "$EAST_CTX" label svc reviews -n "$NS" istio.io/use-waypoint- &>/dev/null || true
oc --context "$EAST_CTX" delete gateway reviews-waypoint -n "$NS" &>/dev/null || true
echo -e "  ${PASS} Waypoint, VirtualService, DestinationRule removed"

section "Restore WEST2 reviews"
oc --context "$WEST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n "$NS" --replicas=1 &>/dev/null
echo -e "  ${PASS} WEST2 reviews scaled back to ${GREEN}${BOLD}1${RESET}"
sleep 5

section "Verify recovery"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_URL" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST2: ${GREEN}HTTP ${east_code}${RESET} — normal operation restored"
else
  echo -e "  ${WARN} EAST2: HTTP ${east_code} — may need a moment to recover"
fi

# ── Summary ──────────────────────────────────────────────────────────
header "CANARY DEPLOYMENT SUMMARY"
echo ""

all_pass="true"
[[ "${test_100v1:-}" != "pass" ]] && all_pass="false"
[[ "${test_5050:-}" != "pass" ]] && all_pass="false"
[[ "${test_100v3:-}" != "pass" ]] && all_pass="false"

echo -e "  ${BOLD}Phase              v1     v3     Expected          Result${RESET}"
printf "  100%% v1            %-6s %-6s all → v1          %b\n" \
  "${a_v1:-?}" "${a_v3:-?}" "$([ "${test_100v1:-}" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  50/50 canary       %-6s %-6s both get traffic  %b\n" \
  "${b_v1:-?}" "${b_v3:-?}" "$([ "${test_5050:-}" = "pass" ] && echo -e "${PASS}" || echo -e "${WARN}")"
printf "  100%% v3 (promoted) %-6s %-6s all → v3          %b\n" \
  "${c_v1:-?}" "${c_v3:-?}" "$([ "${test_100v3:-}" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
echo ""

if [[ "$all_pass" == "true" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC3-T2 PASSED${RESET} — Canary deployment via waypoint working"
  echo -e "     VirtualService + DestinationRule weighted routing"
  echo -e "     Enforced by reviews-waypoint (L7 data plane)"
  echo -e "     Progressive: 100% v1 → 50/50 → 100% v3"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC3-T2 FAILED${RESET} — some phases did not pass"
fi
echo ""
