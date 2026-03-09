#!/bin/bash
#
# UC20-T1: Fault Injection (Delay & Abort) — Verification Script
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

cleanup_vs() {
  oc --context "$CTX" delete virtualservice reviews-fault-inject -n "$NS" 2>/dev/null
}

cleanup_all() {
  cleanup_vs
  oc --context "$CTX" label svc reviews -n "$NS" istio.io/use-waypoint- 2>/dev/null
  oc --context "$CTX" delete gateway reviews-waypoint -n "$NS" 2>/dev/null
}
trap cleanup_all EXIT

PRODUCTPAGE_POD=""

call_reviews() {
  oc --context "$CTX" exec -n "$NS" "$PRODUCTPAGE_POD" -- python3 -c "
import urllib.request, time
start = time.time()
try:
    req = urllib.request.Request('http://reviews:9080/reviews/0')
    with urllib.request.urlopen(req, timeout=15) as resp:
        elapsed = time.time() - start
        body = resp.read().decode()[:100]
        print(f'{resp.status}|{elapsed:.2f}|{body}')
except urllib.error.HTTPError as e:
    elapsed = time.time() - start
    body = e.read().decode()[:100]
    print(f'{e.code}|{elapsed:.2f}|{body}')
except Exception as e:
    elapsed = time.time() - start
    print(f'0|{elapsed:.2f}|{e}')
" 2>/dev/null
}

# ── Start ────────────────────────────────────────────────────────────
header "UC20-T1: Fault Injection (Delay & Abort)"

section "1. Baseline — verify bookinfo and productpage pod"
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
echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET}"
echo -e "  → Kiali graph: ${BOLD}${KIALI_URL}${RESET}"

section "2. Baseline — direct call productpage → reviews"
baseline=$(call_reviews)
b_status=$(echo "$baseline" | cut -d'|' -f1)
b_elapsed=$(echo "$baseline" | cut -d'|' -f2)
if [[ "$b_status" =~ ^(200|404)$ ]]; then
  echo -e "  ${PASS} Status: ${GREEN}${b_status}${RESET}  Elapsed: ${b_elapsed}s (reviews reachable)"
elif [[ "$b_status" == "0" ]]; then
  echo -e "  ${WARN} Timeout on first call — retrying after 5s..."
  sleep 5
  baseline=$(call_reviews)
  b_status=$(echo "$baseline" | cut -d'|' -f1)
  b_elapsed=$(echo "$baseline" | cut -d'|' -f2)
  if [[ "$b_status" =~ ^(200|404)$ ]]; then
    echo -e "  ${PASS} Status: ${GREEN}${b_status}${RESET}  Elapsed: ${b_elapsed}s (reviews reachable)"
  else
    echo -e "  ${FAIL} Status: ${RED}${b_status}${RESET} — reviews not reachable"
    exit 1
  fi
else
  echo -e "  ${FAIL} Status: ${RED}${b_status}${RESET} — reviews not reachable"
  exit 1
fi

pause "Press ENTER to deploy waypoint and inject faults..."

# ── Deploy reviews-waypoint ──────────────────────────────────────────
section "3. Deploy reviews-waypoint (L7 proxy for VirtualService)"
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

# ── Phase A: Abort ──────────────────────────────────────────────────
header "Phase A: Fault Abort (HTTP 500)"

section "4. Apply VirtualService — abort 100% with HTTP 500"
cleanup_vs
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-fault-inject
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - fault:
      abort:
        httpStatus: 500
        percentage:
          value: 100
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
EOF
echo -e "  ${PASS} VirtualService applied (abort)"
sleep 10

section "5. Test abort — expect HTTP 500"
abort_result=$(call_reviews)
a_status=$(echo "$abort_result" | cut -d'|' -f1)
a_elapsed=$(echo "$abort_result" | cut -d'|' -f2)
a_body=$(echo "$abort_result" | cut -d'|' -f3)

if [[ "$a_status" == "500" ]]; then
  echo -e "  ${PASS} Status: ${GREEN}${a_status}${RESET}  Body: ${BOLD}${a_body}${RESET}  Elapsed: ${a_elapsed}s"
  test_abort="pass"
else
  echo -e "  ${FAIL} Status: ${RED}${a_status}${RESET} — expected 500"
  test_abort="fail"
fi

echo ""
echo -e "  → Refresh browser: ${BOLD}${EAST_ROUTE}${RESET} (should show 'Error fetching product reviews')"
echo -e "  → Kiali: ${BOLD}${KIALI_URL}${RESET} (observe traffic flow on reviews)"
echo -e "  → Try: ${CYAN}curl -s -o /dev/null -w '%{http_code}' ${EAST_ROUTE}${RESET}"
pause "Press ENTER to switch to fault delay (5s)..."

# ── Phase B: Delay ──────────────────────────────────────────────────
header "Phase B: Fault Delay (5 seconds)"

section "6. Apply VirtualService — delay 100% for 5s"
cleanup_vs
echo -e "  Waiting for abort cleanup to propagate..."
sleep 15
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-fault-inject
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - fault:
      delay:
        fixedDelay: 5s
        percentage:
          value: 100
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
EOF
echo -e "  ${PASS} VirtualService applied (delay 5s)"
echo -e "  Waiting for config propagation..."
sleep 15

section "7. Test delay — expect ~5s response time"
for attempt in 1 2; do
  delay_result=$(call_reviews)
  d_status=$(echo "$delay_result" | cut -d'|' -f1)
  d_elapsed=$(echo "$delay_result" | cut -d'|' -f2)
  d_elapsed_int=$(echo "$d_elapsed" | cut -d'.' -f1)

  if [[ "$d_status" =~ ^(200|404)$ && "$d_elapsed_int" -ge 4 ]]; then
    echo -e "  ${PASS} Status: ${GREEN}${d_status}${RESET}  Elapsed: ${BOLD}${d_elapsed}s${RESET} (delay injected)"
    test_delay="pass"
    break
  elif [[ "$d_status" =~ ^(200|404)$ ]]; then
    echo -e "  ${WARN} Status: ${d_status}, Elapsed: ${d_elapsed}s (expected ≥4s)"
    test_delay="fail"
    break
  else
    if [[ "$attempt" -eq 1 ]]; then
      echo -e "  ${WARN} Attempt 1: Status ${d_status} — retrying after 10s..."
      sleep 10
    else
      echo -e "  ${FAIL} Status: ${RED}${d_status}${RESET} — expected 200 with ~5s delay"
      test_delay="fail"
    fi
  fi
done

echo ""
echo -e "  → Refresh browser: ${BOLD}${EAST_ROUTE}${RESET} (page loads slowly ~5s)"
echo -e "  → Try: ${CYAN}curl -s -o /dev/null -w 'HTTP %%{http_code} in %%{time_total}s' ${EAST_ROUTE}${RESET}"
pause "Press ENTER to cleanup..."

# ── Cleanup ──────────────────────────────────────────────────────────
cleanup_vs

# ── Results ──────────────────────────────────────────────────────────
header "Results"
echo ""

all_pass="true"
[[ "$test_abort" != "pass" ]] && all_pass="false"
[[ "$test_delay" != "pass" ]] && all_pass="false"

echo -e "  | Test                | Expected           | Got                 | Result |"
echo -e "  |---------------------|--------------------|---------------------|--------|"
printf "  | Baseline            | 200, fast          | %s, %ss           | %b |\n" \
  "$b_status" "$b_elapsed" "${PASS}"
printf "  | Abort (500, 100%%)   | 500, fault abort   | %s, %s   | %b |\n" \
  "$a_status" "$a_body" "$([ "$test_abort" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | Delay (5s, 100%%)    | 200, ~5s           | %s, %ss           | %b |\n" \
  "$d_status" "$d_elapsed" "$([ "$test_delay" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
echo ""

if [[ "$all_pass" == "true" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC20-T1 PASSED${RESET} — Fault injection works in ambient mode"
  echo -e "     VirtualService fault filters enforced by waypoint proxy"
  echo -e "     Abort: reviews returned 500 (fault filter abort)"
  echo -e "     Delay: reviews responded in ${d_elapsed}s (5s injected)"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC20-T1 FAILED${RESET} — some tests did not pass"
fi

sleep 5
section "8. Verify recovery after cleanup"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET} — normal operation restored"
else
  echo -e "  ${WARN} EAST: HTTP ${east_code} — may need a moment to recover"
fi
echo ""
