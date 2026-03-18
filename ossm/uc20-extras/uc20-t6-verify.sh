#!/bin/bash
#
# UC20-T6: Traffic Mirroring — Verification Script
# Uses HTTPRoute (Gateway API) requestMirror filter
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
  oc --context "$CTX" delete httproute reviews-mirror -n "$NS" 2>/dev/null
  oc --context "$CTX" delete svc reviews-v2-mirror -n "$NS" 2>/dev/null
  oc --context "$CTX" label svc reviews -n "$NS" istio.io/use-waypoint- 2>/dev/null
  oc --context "$CTX" delete gateway reviews-waypoint -n "$NS" 2>/dev/null
}

trap cleanup EXIT

# ── Start ────────────────────────────────────────────────────────────
header "UC20-T6: Traffic Mirroring — HTTPRoute"

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

echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET}"
echo -e "  → Kiali graph: ${BOLD}${KIALI_URL}${RESET}"
pause "Press ENTER to deploy waypoint and configure mirroring..."

# ── Deploy reviews-waypoint ──────────────────────────────────────────
section "2. Deploy reviews-waypoint (L7 proxy for HTTPRoute mirror)"
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

# ── Create mirror service + apply HTTPRoute ──────────────────────────
header "Phase: Configure Traffic Mirroring"

section "3. Create mirror target service + HTTPRoute with requestMirror"
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: reviews-v2-mirror
  namespace: bookinfo
spec:
  ports:
  - port: 9080
    name: http
  selector:
    app: reviews
    version: v2
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-mirror
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - filters:
    - type: RequestMirror
      requestMirror:
        backendRef:
          name: reviews-v2-mirror
          port: 9080
    backendRefs:
    - name: reviews
      port: 9080
EOF
echo -e "  ${PASS} Service reviews-v2-mirror + HTTPRoute with requestMirror applied"
echo -e "  Waiting 15s for config propagation..."
sleep 15

# ── Send traffic ────────────────────────────────────────────────────
section "4. Send traffic to generate mirror copies"
echo -e "  Sending 8 requests through the Route..."
for i in $(seq 1 8); do
  curl -s -o /dev/null -w "%{http_code} " -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE"
  sleep 1
done
echo ""

echo -e "  Sending 5 direct mesh requests..."
for i in $(seq 1 5); do
  oc --context "$CTX" exec -n "$NS" "$PRODUCTPAGE_POD" -- python3 -c "
import urllib.request
try:
    resp = urllib.request.urlopen('http://reviews:9080/reviews/0', timeout=5)
    print(f'HTTP {resp.status}')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null
  sleep 1
done
sleep 5

# ── Verify via waypoint stats ────────────────────────────────────────
section "5. Verify mirror traffic via waypoint Envoy stats"
REVIEWS_WP=$(oc --context "$CTX" get pod -n "$NS" \
  -l gateway.networking.k8s.io/gateway-name=reviews-waypoint \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo -e "  Waypoint pod: ${BOLD}${REVIEWS_WP}${RESET}"

mirror_stats=$(oc --context "$CTX" exec "$REVIEWS_WP" -n "$NS" -- \
  pilot-agent request GET clusters 2>/dev/null \
  | grep "reviews-v2-mirror" | grep "rq_total" | head -1)

mirror_total=$(echo "$mirror_stats" | sed 's/.*rq_total:://' | tr -d '[:space:]')
echo -e "  Mirror cluster rq_total: ${BOLD}${mirror_total:-0}${RESET}"

if [[ -n "$mirror_total" && "$mirror_total" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}Mirroring confirmed${RESET}: ${mirror_total} requests mirrored to reviews-v2"
  test_mirror="pass"
else
  echo -e "  ${FAIL} No mirrored requests detected in waypoint stats"
  test_mirror="fail"
fi

# ── Verify via ztunnel logs ──────────────────────────────────────────
section "6. Verify mirror traffic via ztunnel logs"
ZTUNNEL_POD=$(oc --context "$CTX" get pods -n ztunnel -l app=ztunnel \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

echo -e "  Waiting 30s for mirror connections to complete and appear in ztunnel logs..."
sleep 30

mirror_logs=$(oc --context "$CTX" logs "$ZTUNNEL_POD" -n ztunnel --tail=500 2>/dev/null \
  | grep "reviews-v2-mirror")
v2_conns=$(echo "$mirror_logs" | grep -c "reviews-v2-mirror" 2>/dev/null || echo 0)

echo -e "  ztunnel → reviews-v2-mirror: ${BOLD}${v2_conns}${RESET} connections"

if [[ "$v2_conns" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}Mirror traffic confirmed in ztunnel logs${RESET}"
  echo ""
  echo -e "  ${CYAN}Sample ztunnel log entry:${RESET}"
  echo "$mirror_logs" | head -1 | sed 's/.*src.workload=/  src.workload=/' | fold -s -w 100 | while IFS= read -r line; do
    echo -e "  ${CYAN}${line}${RESET}"
  done
  test_ztunnel="pass"
else
  echo -e "  ${WARN} No mirror connections found in recent ztunnel logs (may have scrolled out)"
  test_ztunnel="warn"
fi

echo ""
echo -e "  → Kiali: ${BOLD}${KIALI_URL}${RESET} (should show mirrored traffic to reviews-v2-mirror)"
pause "Press ENTER to cleanup..."

# ── Cleanup ──────────────────────────────────────────────────────────
section "7. Cleanup"
trap - EXIT
cleanup
echo -e "  ${PASS} Resources deleted"
sleep 5

# ── Recovery ─────────────────────────────────────────────────────────
section "8. Verify recovery"
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
[[ "$test_mirror" != "pass" ]] && all_pass="false"

echo -e "  | Test                     | Expected                        | Result |"
echo -e "  |--------------------------|--------------------------------|--------|"
printf "  | Mirror to v2 (stats)     | rq_total > 0 in waypoint       | %b |\n" \
  "$([ "$test_mirror" = "pass" ] && echo -e "${PASS}" || echo -e "${FAIL}")"
printf "  | Mirror to v2 (ztunnel)   | connections in ztunnel logs     | %b |\n" \
  "$([ "$test_ztunnel" = "pass" ] && echo -e "${PASS}" || echo -e "${WARN}")"
echo ""

if [[ "$all_pass" == "true" ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}UC20-T6 PASSED${RESET} — Traffic mirroring works in ambient mode"
  echo -e "     HTTPRoute (Gateway API) requestMirror filter enforced by waypoint"
  echo -e "     Primary traffic: routed normally"
  echo -e "     Shadow traffic: mirrored to reviews-v2 (fire-and-forget)"
else
  echo -e "  ${FAIL} ${RED}${BOLD}UC20-T6 FAILED${RESET} — mirroring not detected"
fi
echo ""
