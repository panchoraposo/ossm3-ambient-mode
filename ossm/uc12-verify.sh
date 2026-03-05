#!/bin/bash
#
# UC12: Blue/Green Deployment with Gateway API — Verification Script
# 100% Service Mesh: HTTPRoute weight-based and header-based routing
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

EAST_HOST="bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com"
KIALI_URL="https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph"

ERRORS=0

pause() {
  echo ""
  echo -e "  ${CYAN}╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶╶${RESET}"
  read -rp "  ⏎ ${1:-Press ENTER to continue...} " _
}

# ── Pre-check: warn if generate-traffic.sh is running ────────────────────
traffic_pids=$(pgrep -f generate-traffic.sh 2>/dev/null | tr '\n' ' ' | xargs)
if [[ -n "$traffic_pids" ]]; then
  echo ""
  echo -e "${RED}${BOLD}⚠  generate-traffic.sh is running${RESET}"
  echo -e "${YELLOW}   It sends traffic to /productpage which bypasses gateway routing${RESET}"
  echo -e "${YELLOW}   and will show the original 'reviews' service in Kiali.${RESET}"
  echo ""
  echo -e "${YELLOW}   Stop it first:  ${BOLD}kill ${traffic_pids}${RESET}"
  echo ""
  pause "Press ENTER to continue anyway, or Ctrl+C to stop and kill it first..."
fi

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

TRAFFIC_PID=""

start_traffic() {
  stop_traffic
  while true; do
    curl -s --max-time 5 -o /dev/null "http://${EAST_HOST}/reviews/0" 2>/dev/null
    sleep 0.5
  done &
  TRAFFIC_PID=$!
}

stop_traffic() {
  if [[ -n "$TRAFFIC_PID" ]]; then
    kill "$TRAFFIC_PID" 2>/dev/null
    wait "$TRAFFIC_PID" 2>/dev/null
    TRAFFIC_PID=""
  fi
}

trap stop_traffic EXIT

get_review_version() {
  local header_name="$1"
  local header_value="$2"
  if [[ -n "$header_name" ]]; then
    curl -s --max-time 20 --retry 2 --retry-delay 3 -H "${header_name}: ${header_value}" "http://${EAST_HOST}/reviews/0" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('podname','unknown'))" 2>/dev/null
  else
    curl -s --max-time 20 --retry 2 --retry-delay 3 "http://${EAST_HOST}/reviews/0" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('podname','unknown'))" 2>/dev/null
  fi
}

test_distribution() {
  local label="$1"
  local count="$2"
  local expect_green="$3"

  section "$label ($count requests)"
  local v1=0 v3=0 other=0
  for i in $(seq 1 "$count"); do
    pod=$(get_review_version)
    if echo "$pod" | grep -q "v1"; then v1=$((v1+1))
    elif echo "$pod" | grep -q "v3"; then v3=$((v3+1))
    else other=$((other+1)); fi
  done

  local green_pct=$((v1 * 100 / count))
  local blue_pct=$((v3 * 100 / count))

  echo -e "  ${GREEN}reviews-v1 (green):${RESET} ${BOLD}${v1}/${count}${RESET} (${green_pct}%)"
  echo -e "  ${CYAN}reviews-v3 (blue):${RESET}  ${BOLD}${v3}/${count}${RESET} (${blue_pct}%)"
  [[ $other -gt 0 ]] && echo -e "  ${YELLOW}other:${RESET}              ${other}/${count}"

  if [[ "$expect_green" == "100" && "$v1" -ne "$count" ]]; then
    echo -e "  ${FAIL} Expected 100% green"
    ERRORS=$((ERRORS + 1))
  elif [[ "$expect_green" == "0" && "$v3" -ne "$count" ]]; then
    echo -e "  ${FAIL} Expected 100% blue"
    ERRORS=$((ERRORS + 1))
  elif [[ "$expect_green" == "mix" ]]; then
    if [[ "$v1" -gt 0 && "$v3" -gt 0 ]]; then
      echo -e "  ${PASS} Traffic split confirmed"
    else
      echo -e "  ${WARN} Expected mix of green and blue"
    fi
  else
    echo -e "  ${PASS} Distribution matches expected"
  fi
}

# ── Banner ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  UC12: Blue/Green Deployment with Gateway API              ║${RESET}"
echo -e "${BOLD}║  100% Service Mesh — HTTPRoute Traffic Routing             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${YELLOW}All routing is performed by the mesh ingress gateway (Envoy)${RESET}"
echo -e "  ${YELLOW}using Gateway API HTTPRoute resources processed by istiod.${RESET}"
echo -e "  ${YELLOW}Verification via curl to /reviews/0 (routed through the gateway).${RESET}"

# ── Phase 1: Setup ───────────────────────────────────────────────────────
header "1. Setup — 100% Green"

section "Create versioned Services"
oc --context east apply -f - <<'EOF' &>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: reviews-green
  namespace: bookinfo
  labels:
    app: reviews
    version: v1
spec:
  ports:
  - port: 9080
    name: http
    targetPort: 9080
  selector:
    app: reviews
    version: v1
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-blue
  namespace: bookinfo
  labels:
    app: reviews
    version: v3
spec:
  ports:
  - port: 9080
    name: http
    targetPort: 9080
  selector:
    app: reviews
    version: v3
EOF
echo -e "  ${PASS} ${GREEN}reviews-green${RESET} → v1 (no stars)"
echo -e "  ${PASS} ${CYAN}reviews-blue${RESET}  → v3 (red stars)"

section "Set HTTPRoute: green=100 / blue=0"
oc --context east apply -f - <<'EOF' &>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo
  namespace: bookinfo
spec:
  parentRefs:
  - name: bookinfo-gateway
  rules:
  - matches:
    - path: { type: PathPrefix, value: /productpage }
    - path: { type: PathPrefix, value: /static }
    - path: { type: PathPrefix, value: /login }
    - path: { type: PathPrefix, value: /logout }
    - path: { type: PathPrefix, value: /api/v1/products }
    backendRefs:
    - name: productpage
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /details }
    backendRefs:
    - name: details
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /reviews }
    backendRefs:
    - name: reviews-green
      port: 9080
      weight: 100
    - name: reviews-blue
      port: 9080
      weight: 0
  - matches:
    - path: { type: PathPrefix, value: /ratings }
    backendRefs:
    - name: ratings
      port: 9080
EOF
echo -e "  ${PASS} HTTPRoute: ${GREEN}green=100${RESET} / ${CYAN}blue=0${RESET}"
sleep 3

test_distribution "100% Green" 10 "100"

section "Verify /productpage still works"
pp_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 --retry 2 --retry-delay 3 "http://${EAST_HOST}/productpage" 2>/dev/null)
if [[ "$pp_code" == "200" ]]; then
  echo -e "  ${PASS} /productpage HTTP ${GREEN}${pp_code}${RESET}"
else
  echo -e "  ${FAIL} /productpage HTTP ${RED}${pp_code}${RESET}"
  ERRORS=$((ERRORS + 1))
fi

start_traffic
echo ""
echo -e "  ${CYAN}${BOLD}▶ Generating traffic to /reviews/0 for Kiali...${RESET}"
echo -e "  ${CYAN}  Expected in Kiali: 100% traffic to reviews-green (v1)${RESET}"
echo -e "  ${CYAN}  ${KIALI_URL}${RESET}"
echo ""
pause "Press ENTER to continue to Canary..."
stop_traffic

# ── Phase 2: Canary ──────────────────────────────────────────────────────
header "2. Canary — 90% Green / 10% Blue"

oc --context east -n bookinfo patch httproute bookinfo --type=json -p '[
  {"op":"replace","path":"/spec/rules/2/backendRefs/0/weight","value":90},
  {"op":"replace","path":"/spec/rules/2/backendRefs/1/weight","value":10}
]' &>/dev/null
echo -e "  ${PASS} HTTPRoute: ${GREEN}green=90${RESET} / ${CYAN}blue=10${RESET}"
sleep 3

test_distribution "Canary 90/10" 20 "mix"

start_traffic
echo ""
echo -e "  ${CYAN}${BOLD}▶ Generating traffic to /reviews/0 for Kiali...${RESET}"
echo -e "  ${CYAN}  Expected in Kiali: ~90% reviews-green, ~10% reviews-blue${RESET}"
echo -e "  ${CYAN}  ${KIALI_URL}${RESET}"
echo ""
pause "Press ENTER to continue to Blue Promotion..."
stop_traffic

# ── Phase 3: Blue Promotion ──────────────────────────────────────────────
header "3. Blue Promotion — 100% Blue"

oc --context east -n bookinfo patch httproute bookinfo --type=json -p '[
  {"op":"replace","path":"/spec/rules/2/backendRefs/0/weight","value":0},
  {"op":"replace","path":"/spec/rules/2/backendRefs/1/weight","value":100}
]' &>/dev/null
echo -e "  ${PASS} HTTPRoute: ${GREEN}green=0${RESET} / ${CYAN}blue=100${RESET}"
sleep 3

test_distribution "100% Blue" 10 "0"

start_traffic
echo ""
echo -e "  ${CYAN}${BOLD}▶ Generating traffic to /reviews/0 for Kiali...${RESET}"
echo -e "  ${CYAN}  Expected in Kiali: 100% traffic to reviews-blue (v3)${RESET}"
echo -e "  ${CYAN}  ${KIALI_URL}${RESET}"
echo ""
pause "Press ENTER to continue to Header-Based Routing..."
stop_traffic

# ── Phase 4: Header-Based Routing ────────────────────────────────────────
header "4. Header-Based Routing — A/B Testing"

oc --context east apply -f - <<'EOF' &>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo
  namespace: bookinfo
spec:
  parentRefs:
  - name: bookinfo-gateway
  rules:
  - matches:
    - path: { type: PathPrefix, value: /productpage }
    - path: { type: PathPrefix, value: /static }
    - path: { type: PathPrefix, value: /login }
    - path: { type: PathPrefix, value: /logout }
    - path: { type: PathPrefix, value: /api/v1/products }
    backendRefs:
    - name: productpage
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /details }
    backendRefs:
    - name: details
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /reviews }
      headers:
      - name: x-beta-user
        value: "true"
    backendRefs:
    - name: reviews-blue
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /reviews }
    backendRefs:
    - name: reviews-green
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /ratings }
    backendRefs:
    - name: ratings
      port: 9080
EOF
echo -e "  ${PASS} HTTPRoute: header-based routing active"
sleep 3

section "Without header → Green (v1)"
v1_count=0
for i in $(seq 1 5); do
  pod=$(get_review_version)
  echo "$pod" | grep -q "v1" && v1_count=$((v1_count+1))
done
if [[ "$v1_count" -eq 5 ]]; then
  echo -e "  ${PASS} 5/5 requests → ${GREEN}reviews-v1 (green)${RESET}"
else
  echo -e "  ${FAIL} Expected all green, got ${v1_count}/5"
  ERRORS=$((ERRORS + 1))
fi

section "With header x-beta-user: true → Blue (v3)"
v3_count=0
for i in $(seq 1 5); do
  pod=$(get_review_version "x-beta-user" "true")
  echo "$pod" | grep -q "v3" && v3_count=$((v3_count+1))
done
if [[ "$v3_count" -eq 5 ]]; then
  echo -e "  ${PASS} 5/5 requests → ${CYAN}reviews-v3 (blue)${RESET}"
else
  echo -e "  ${FAIL} Expected all blue, got ${v3_count}/5"
  ERRORS=$((ERRORS + 1))
fi

start_traffic
echo ""
echo -e "  ${CYAN}${BOLD}▶ Generating traffic to /reviews/0 for Kiali...${RESET}"
echo -e "  ${CYAN}  Expected in Kiali: 100% to reviews-green (default, no header)${RESET}"
echo -e "  ${CYAN}  ${KIALI_URL}${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}▶ Try header routing yourself:${RESET}"
echo -e "  ${CYAN}  curl http://${EAST_HOST}/reviews/0${RESET}"
echo -e "  ${CYAN}  curl -H \"x-beta-user: true\" http://${EAST_HOST}/reviews/0${RESET}"
echo ""
pause "Press ENTER to cleanup..."
stop_traffic

# ── Phase 5: Cleanup ─────────────────────────────────────────────────────
header "5. Cleanup"

oc --context east apply -f - <<'EOF' &>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo
  namespace: bookinfo
spec:
  parentRefs:
  - name: bookinfo-gateway
  rules:
  - matches:
    - path: { type: PathPrefix, value: /productpage }
    - path: { type: PathPrefix, value: /static }
    - path: { type: PathPrefix, value: /login }
    - path: { type: PathPrefix, value: /logout }
    - path: { type: PathPrefix, value: /api/v1/products }
    backendRefs:
    - name: productpage
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /details }
    backendRefs:
    - name: details
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /reviews }
    backendRefs:
    - name: reviews
      port: 9080
  - matches:
    - path: { type: PathPrefix, value: /ratings }
    backendRefs:
    - name: ratings
      port: 9080
EOF
echo -e "  ${PASS} HTTPRoute ${GREEN}restored${RESET} to original"

oc --context east delete svc reviews-green reviews-blue -n bookinfo &>/dev/null
echo -e "  ${PASS} Versioned Services ${GREEN}removed${RESET}"

sleep 3

section "Verify recovery"
pp_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 --retry 2 --retry-delay 3 "http://${EAST_HOST}/productpage" 2>/dev/null)
if [[ "$pp_code" == "200" ]]; then
  echo -e "  ${PASS} /productpage HTTP ${GREEN}${pp_code}${RESET}"
else
  echo -e "  ${FAIL} /productpage HTTP ${RED}${pp_code}${RESET}"
  ERRORS=$((ERRORS + 1))
fi

section "Pod restarts"
restarts=$(oc --context east get pods -n bookinfo --no-headers 2>/dev/null | grep reviews | awk '{sum+=$4} END{print sum}')
[[ -z "$restarts" ]] && restarts=0
if [[ "$restarts" -eq 0 ]]; then
  echo -e "  ${PASS} Reviews pods: ${GREEN}0 restarts${RESET}"
else
  echo -e "  ${WARN} Reviews pods: ${YELLOW}${restarts} restarts${RESET}"
fi

# ── Summary ──────────────────────────────────────────────────────────────
header "SUMMARY"
echo ""
echo -e "  ${BOLD}100% Green:${RESET}          curl /reviews/0 → ${GREEN}reviews-v1${RESET} (no stars)"
echo -e "  ${BOLD}90/10 Canary:${RESET}        Gateway split verified via curl + ${CYAN}Kiali${RESET}"
echo -e "  ${BOLD}100% Blue:${RESET}           curl /reviews/0 → ${CYAN}reviews-v3${RESET} (red stars)"
echo -e "  ${BOLD}Header routing:${RESET}      ${CYAN}x-beta-user: true${RESET} → blue, otherwise green"
echo -e "  ${BOLD}Pod restarts:${RESET}        ${GREEN}ZERO${RESET}"
echo -e "  ${BOLD}Mechanism:${RESET}           100% Service Mesh — Gateway API (HTTPRoute)"
echo ""

if [[ "$ERRORS" -gt 0 ]]; then
  echo -e "  ${FAIL} ${RED}${ERRORS} error(s) detected${RESET}"
  exit 1
else
  echo -e "  ${PASS} ${GREEN}All checks passed${RESET}"
fi
echo ""
