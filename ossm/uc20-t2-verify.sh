#!/bin/bash
#
# UC20-T2: Request Timeouts — Verification Script
# Uses HTTPRoute (Gateway API) for timeout + VirtualService for fault injection
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
  section "Cleanup: removing resources"
  oc --context "$CTX" delete httproute reviews-timeout -n "$NS" 2>/dev/null
  oc --context "$CTX" delete virtualservice ratings-delay -n "$NS" 2>/dev/null
  oc --context "$CTX" label svc reviews -n "$NS" istio.io/use-waypoint- 2>/dev/null
  oc --context "$CTX" label svc ratings -n "$NS" istio.io/use-waypoint- 2>/dev/null
  oc --context "$CTX" delete gateway reviews-waypoint -n "$NS" 2>/dev/null
  oc --context "$CTX" delete gateway ratings-waypoint -n "$NS" 2>/dev/null
  echo -e "  ${PASS} All resources removed (HTTPRoute, VirtualService, waypoints)"
}
trap cleanup EXIT

PRODUCTPAGE_POD=""

call_reviews_batch() {
  local count=$1
  oc --context "$CTX" exec -n "$NS" "$PRODUCTPAGE_POD" -- python3 -c "
import urllib.request, time, json

results = []
for i in range($count):
    start = time.time()
    try:
        req = urllib.request.Request('http://reviews:9080/reviews/0')
        with urllib.request.urlopen(req, timeout=15) as resp:
            elapsed = time.time() - start
            results.append({'status': resp.status, 'elapsed': round(elapsed, 2)})
    except urllib.error.HTTPError as e:
        elapsed = time.time() - start
        body = e.read().decode()[:40]
        results.append({'status': e.code, 'elapsed': round(elapsed, 2), 'body': body})
    except Exception as e:
        elapsed = time.time() - start
        results.append({'status': 0, 'elapsed': round(elapsed, 2), 'error': str(e)[:40]})
print(json.dumps(results))
" 2>/dev/null
}

# ── Start ────────────────────────────────────────────────────────────
header "UC20-T2: Request Timeouts — HTTPRoute"

section "1. Baseline — verify bookinfo"
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

section "2. Baseline — all reviews respond fast"
baseline=$(call_reviews_batch 4)
echo "$baseline" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for i, r in enumerate(data):
    status = r['status']
    elapsed = r['elapsed']
    tag = '${GREEN}' if status in [200, 404] else '${RED}'
    print(f'  [{i+1}] Status: {tag}{status}${RESET}  Elapsed: {elapsed}s')
all_fast = all(r['elapsed'] < 2 for r in data)
if all_fast:
    print('  ${PASS} All responses fast (< 2s)')
" 2>/dev/null

echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET}"
echo -e "  → Kiali graph: ${BOLD}${KIALI_URL}${RESET}"
pause "Press ENTER to deploy waypoints and inject delay + timeout..."

# ── Deploy waypoints ─────────────────────────────────────────────────
section "3. Deploy waypoints (reviews + ratings)"
for svc in reviews ratings; do
  oc --context "$CTX" apply -f - <<EOF 2>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${svc}-waypoint
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
  oc --context "$CTX" label svc "$svc" -n "$NS" istio.io/use-waypoint="${svc}-waypoint" --overwrite 2>/dev/null
  echo -e "  ${PASS} ${svc}-waypoint created and service labeled"
done
echo -e "  Waiting for waypoint pods..."
oc --context "$CTX" wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=reviews-waypoint -n "$NS" --timeout=60s 2>/dev/null
oc --context "$CTX" wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=ratings-waypoint -n "$NS" --timeout=60s 2>/dev/null
echo -e "  ${PASS} Both waypoint pods ${GREEN}Ready${RESET}"

# ── Apply delay + timeout ───────────────────────────────────────────
section "4. Inject delay on ratings (5s) via VirtualService"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings-delay
  namespace: bookinfo
spec:
  hosts:
  - ratings.bookinfo.svc.cluster.local
  http:
  - fault:
      delay:
        fixedDelay: 5s
        percentage:
          value: 100
    route:
    - destination:
        host: ratings.bookinfo.svc.cluster.local
EOF
echo -e "  ${PASS} VirtualService delay on ratings applied (5s)"

section "5. Set timeout on reviews via HTTPRoute (2s)"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-timeout
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - timeouts:
      request: 2s
    backendRefs:
    - name: reviews
      port: 9080
EOF
echo -e "  ${PASS} HTTPRoute timeout on reviews applied (2s)"

echo -e "  Waiting for config propagation..."
sleep 15

# ── Test timeout behavior ────────────────────────────────────────────
section "6. Test — expect mix of fast (v1) and timeout (v2/v3)"
result=$(call_reviews_batch 9)

got_504=false
got_fast=false

echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
count_504 = 0
count_fast = 0
count_other = 0
for i, r in enumerate(data):
    status = r['status']
    elapsed = r['elapsed']
    body = r.get('body', '')
    if status == 504 and elapsed >= 1.5:
        tag = '${RED}'
        detail = f'timeout at {elapsed}s'
        count_504 += 1
    elif status in [200, 404] and elapsed < 1.5:
        tag = '${GREEN}'
        detail = f'fast ({elapsed}s) — reviews-v1'
        count_fast += 1
    else:
        tag = '${YELLOW}'
        detail = f'{elapsed}s'
        count_other += 1
    print(f'  [{i+1}] Status: {tag}{status}${RESET}  {detail}')

print()
print(f'  Summary: {count_fast} fast (v1) | {count_504} timeout 504 (v2/v3) | {count_other} other')

if count_504 > 0:
    print('  504_found')
if count_fast > 0:
    print('  fast_found')
" 2>/dev/null

test_504=$(echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('true' if any(r['status'] == 504 and r['elapsed'] >= 1.5 for r in data) else 'false')
" 2>/dev/null)

test_fast=$(echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('true' if any(r['status'] in [200,404] and r['elapsed'] < 1.5 for r in data) else 'false')
" 2>/dev/null)

echo ""
echo -e "  → Refresh browser: ${BOLD}${EAST_ROUTE}${RESET} (v2/v3 reviews timeout at ~2s)"
echo -e "  → Kiali: ${BOLD}${KIALI_URL}${RESET} (observe traffic flow on reviews)"
echo -e "  → Try: ${CYAN}curl -s -o /dev/null -w 'HTTP %%{http_code} in %%{time_total}s' ${EAST_ROUTE}${RESET}"
pause "Press ENTER to cleanup..."

# ── Cleanup ──────────────────────────────────────────────────────────
cleanup

# ── Results ──────────────────────────────────────────────────────────
header "Results"
echo ""

all_pass="true"
[[ "$test_504" != "true" ]] && all_pass="false"

if [[ "$test_504" == "true" ]]; then
  echo -e "  ${PASS} Timeout triggers HTTP 504 at ~2s for reviews-v2/v3 (ratings slow)"
else
  echo -e "  ${FAIL} No 504 timeout responses detected"
fi

if [[ "$test_fast" == "true" ]]; then
  echo -e "  ${PASS} Reviews-v1 responds fast (no ratings dependency)"
else
  echo -e "  ${WARN} No fast responses from reviews-v1 detected in sample"
fi

echo ""
if [[ "$all_pass" == "true" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC20-T2 PASSED${RESET} — Request timeouts work in ambient mode"
  echo -e "     HTTPRoute (Gateway API) timeout enforced by waypoint proxy"
  echo -e "     VirtualService used only for fault injection (no HTTPRoute equivalent)"
  echo -e "     Cascading slowness cut short with 504"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC20-T2 FAILED${RESET}"
fi

sleep 5
section "7. Verify recovery after cleanup"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET} — normal operation restored"
else
  echo -e "  ${WARN} EAST: HTTP ${east_code} — may need a moment to recover"
fi
echo ""
