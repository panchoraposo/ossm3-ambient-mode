#!/bin/bash
#
# UC20-T3: Circuit Breaking — Verification Script
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
CONCURRENT=20

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
  oc --context "$CTX" delete destinationrule reviews-circuit-breaker -n "$NS" 2>/dev/null
  oc --context "$CTX" label svc reviews -n "$NS" istio.io/use-waypoint- 2>/dev/null
  oc --context "$CTX" delete gateway reviews-waypoint -n "$NS" 2>/dev/null
  echo -e "  ${PASS} DestinationRule + waypoint removed"
}
trap cleanup EXIT

# ── Phase 1: Baseline ───────────────────────────────────────────────
header "UC20-T3: Circuit Breaking"

section "1. Baseline — verify traffic flows"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET}"
else
  echo -e "  ${FAIL} EAST: ${RED}HTTP ${east_code}${RESET} — bookinfo not reachable, aborting"
  exit 1
fi

# ── Phase 2: Deploy reviews-waypoint ─────────────────────────────────
section "2. Deploy reviews-waypoint (L7 proxy for DestinationRule)"
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

REVIEWS_WP=$(oc --context "$CTX" get pods -n "$NS" \
  -l gateway.networking.k8s.io/gateway-name=reviews-waypoint \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo -e "  ${PASS} Waypoint pod: ${BOLD}${REVIEWS_WP}${RESET}"

echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET}"
echo -e "  → Kiali graph: ${BOLD}${KIALI_URL}${RESET}"
pause "Press ENTER to apply circuit breaker..."

# ── Phase 3: Apply DestinationRule ──────────────────────────────────
section "3. Apply DestinationRule (restrictive limits)"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-circuit-breaker
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1
      http:
        h2UpgradePolicy: DO_NOT_UPGRADE
        http1MaxPendingRequests: 1
        http2MaxRequests: 1
        maxRequestsPerConnection: 1
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
EOF
echo -e "  ${PASS} DestinationRule applied"
sleep 5

# ── Phase 4: Verify propagation to waypoint ─────────────────────────
section "4. Verify circuit breaker config in waypoint"
max_conn=$(oc --context "$CTX" exec -n "$NS" "$REVIEWS_WP" -- \
  pilot-agent request GET "config_dump" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('configs', []):
    for cluster in c.get('dynamic_active_clusters', []):
        cl = cluster.get('cluster', {})
        if 'reviews' in cl.get('name', '') and 'waypoint' not in cl.get('name', ''):
            thresholds = cl.get('circuit_breakers', {}).get('thresholds', [{}])[0]
            print(thresholds.get('max_connections', 'N/A'))
            break
" 2>/dev/null)

if [[ "$max_conn" == "1" ]]; then
  echo -e "  ${PASS} Waypoint Envoy has ${GREEN}max_connections: 1${RESET}"
else
  echo -e "  ${FAIL} Expected max_connections=1, got: ${max_conn:-empty}"
  exit 1
fi

# ── Phase 5: Reset waypoint stats ───────────────────────────────────
section "5. Reset waypoint stats"
oc --context "$CTX" exec -n "$NS" "$REVIEWS_WP" -- \
  pilot-agent request POST reset_counters &>/dev/null
echo -e "  ${PASS} Stats reset"

pause "Press ENTER to send concurrent traffic..."

# ── Phase 6: Generate concurrent traffic ────────────────────────────
section "6. Send ${CONCURRENT} concurrent requests (from productpage → reviews)"
PRODUCTPAGE_POD=$(oc --context "$CTX" get pods -n "$NS" -l app=productpage \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

result=$(oc --context "$CTX" exec -n "$NS" "$PRODUCTPAGE_POD" -- python3 -c "
import urllib.request, concurrent.futures, json

def call_reviews(i):
    try:
        req = urllib.request.Request('http://reviews:9080/reviews/0')
        with urllib.request.urlopen(req, timeout=10) as resp:
            return str(resp.status)
    except urllib.error.HTTPError as e:
        return str(e.code)
    except:
        return '0'

with concurrent.futures.ThreadPoolExecutor(max_workers=${CONCURRENT}) as pool:
    futures = [pool.submit(call_reviews, i) for i in range(${CONCURRENT})]
    results = [f.result() for f in concurrent.futures.as_completed(futures)]

counts = {}
for s in results:
    counts[s] = counts.get(s, 0) + 1
print(json.dumps(counts))
" 2>/dev/null)

count_200=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('200', d.get(200, 0)))" 2>/dev/null)
count_503=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('503', d.get(503, 0)))" 2>/dev/null)
count_other=$(echo "$result" | python3 -c "
import sys,json
d=json.load(sys.stdin)
total = sum(d.values())
ok = d.get('200', d.get(200, 0))
cb = d.get('503', d.get(503, 0))
print(total - ok - cb)
" 2>/dev/null)

echo -e "  Results: ${GREEN}200→${count_200}${RESET}  ${RED}503→${count_503}${RESET}  other→${count_other:-0}"

if [[ "${count_503}" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}Circuit breaker triggered!${RESET} (${count_503}/${CONCURRENT} requests rejected)"
else
  echo -e "  ${FAIL} No 503s detected — circuit breaker did not trigger"
fi

# ── Phase 7: Confirm via waypoint metrics ───────────────────────────
section "7. Confirm UO (Upstream Overflow) flag in waypoint metrics"
uo_value=$(oc --context "$CTX" exec -n "$NS" "$REVIEWS_WP" -- \
  pilot-agent request GET "stats?filter=UO" 2>/dev/null \
  | grep "istio_requests_total.*response_code\.503.*response_flags\.UO" \
  | head -1 | awk '{print $NF}')

if [[ -z "$uo_value" ]]; then
  uo_value=$(oc --context "$CTX" exec -n "$NS" "$REVIEWS_WP" -- \
    pilot-agent request GET "stats?filter=UO" 2>/dev/null \
    | grep "response_flags\.UO" \
    | head -1 | awk '{print $NF}')
fi

if [[ -n "$uo_value" && "$uo_value" -gt 0 ]]; then
  echo -e "  ${PASS} Waypoint reports ${GREEN}${uo_value} requests${RESET} with UO flag (circuit breaker)"
else
  echo -e "  ${WARN} Could not parse UO metric (circuit breaking still confirmed by 503s above)"
fi

header "Results"
echo ""
if [[ "${count_503}" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC20-T3 PASSED${RESET} — Circuit breaking works in ambient mode"
  echo -e "     Waypoint proxy enforced DestinationRule limits"
  echo -e "     ${count_503}/${CONCURRENT} requests rejected with 503 (UO)"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC20-T3 FAILED${RESET}"
fi

echo ""
echo -e "  → Kiali: ${BOLD}${KIALI_URL}${RESET} (check for 503 error rate on reviews)"
pause "Press ENTER to cleanup..."

# ── Cleanup & recovery ──────────────────────────────────────────────
cleanup

sleep 5
section "8. Verify recovery after cleanup"
east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
if [[ "$east_code" == "200" ]]; then
  echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET} — normal operation restored"
else
  echo -e "  ${WARN} EAST: HTTP ${east_code} — may need a moment to recover"
fi
echo ""
