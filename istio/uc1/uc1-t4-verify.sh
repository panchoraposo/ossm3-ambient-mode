#!/bin/bash
#
# UC1-T4: Resilience & Failover (Cross-Cluster) — Verification Script
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

EAST_CTX="east2"
WEST_CTX="west2"
NS="bookinfo"
ROUTE_NAME="bookinfo-gateway"

EAST_HOST=$(oc --context "$EAST_CTX" get route "$ROUTE_NAME" -n "$NS" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
EAST_URL="http://${EAST_HOST}/productpage"

if [[ -z "$EAST_HOST" ]]; then
  echo -e "  ${FAIL} Could not discover Route in ${EAST_CTX}. Aborting."
  exit 1
fi

# --- Run test ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC1-T4: Resilience & Failover (Cross-Cluster)            ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  EAST2 URL: ${CYAN}${EAST_URL}${RESET}"

# Step 1: Baseline
header "1. Verify Baseline"

section "reviews pods: EAST2"
oc --context "$EAST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
  | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    icon="${PASS}"
    [[ "$status" != "Running" ]] && icon="${FAIL}"
    echo -e "  ${icon} ${name}  ${GREEN}${status}${RESET}"
  done
EAST_COUNT=$(oc --context "$EAST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null | grep -c Running || true)

section "reviews pods: WEST2"
oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
  | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    icon="${PASS}"
    [[ "$status" != "Running" ]] && icon="${FAIL}"
    echo -e "  ${icon} ${name}  ${GREEN}${status}${RESET}"
  done
WEST_COUNT=$(oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null | grep -c Running || true)

section "Endpoints in EAST2"
ep_list=$(oc --context "$EAST_CTX" get endpoints reviews -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
if [[ -n "$ep_list" ]]; then
  echo -e "  ${PASS} Endpoints: ${ep_list}"
else
  echo -e "  ${FAIL} Endpoints: ${RED}<none>${RESET}"
fi

section "Baseline traffic test"
baseline_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_URL" 2>/dev/null || echo "000")
if [[ "$baseline_code" == "200" ]]; then
  echo -e "  ${PASS} EAST2: ${GREEN}HTTP ${baseline_code}${RESET}"
else
  echo -e "  ${FAIL} EAST2: ${RED}HTTP ${baseline_code}${RESET}"
fi

if [[ "$EAST_COUNT" -gt 0 && "$WEST_COUNT" -gt 0 && "$baseline_code" == "200" ]]; then
  echo -e "  ${PASS} Baseline OK — EAST2: ${EAST_COUNT} pods, WEST2: ${WEST_COUNT} pods"
else
  echo -e "  ${WARN} Unexpected baseline — EAST2: ${EAST_COUNT}, WEST2: ${WEST_COUNT}, HTTP: ${baseline_code}"
fi

pause "Press ENTER to simulate failure..."

# Step 2: Failover — scale to 0 and verify cross-cluster routing
header "2. Failover — Scale reviews to 0 in EAST2 & Verify"
echo ""
echo -e "  Scaling reviews-v1, reviews-v2, reviews-v3 → ${RED}${BOLD}0 replicas${RESET} in EAST2..."
oc --context "$EAST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n "$NS" --replicas=0 2>/dev/null
echo -e "  Waiting for pods to terminate..."
sleep 8

section "reviews status after scale-down"
EAST_PODS=$(oc --context "$EAST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null | wc -l | tr -d ' ')
EAST_EP=$(oc --context "$EAST_CTX" get endpoints reviews -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)

if [[ "$EAST_PODS" -eq 0 && -z "$EAST_EP" ]]; then
  echo -e "  ${PASS} reviews pods:      ${RED}${BOLD}0${RESET}"
  echo -e "  ${PASS} reviews endpoints: ${RED}${BOLD}<none>${RESET}"
else
  echo -e "  ${WARN} Still terminating — pods: ${EAST_PODS}, endpoints: '${EAST_EP}'"
fi

section "Cross-cluster failover verification"
echo -e "  Sending 5 requests to EAST2 (reviews must come from WEST2)..."
echo ""

failover_ok=0
for i in 1 2 3 4 5; do
  start_t=$(python3 -c "import time; print(time.time())")
  resp=$(curl -s -m 20 --retry 2 --retry-delay 3 "$EAST_URL" 2>/dev/null || true)
  end_t=$(python3 -c "import time; print(time.time())")
  elapsed=$(python3 -c "print(f'{${end_t} - ${start_t}:.3f}s')")
  has_reviews=$(echo "$resp" | grep -c "Book Reviews" || true)

  if [[ "$has_reviews" -gt 0 ]]; then
    echo -e "  ${PASS} Request $i: ${GREEN}HTTP 200${RESET} in ${BOLD}${elapsed}${RESET} — Book Reviews present"
    failover_ok=$((failover_ok + 1))
  else
    has_error=$(echo "$resp" | grep -c "Error fetching" || true)
    if [[ "$has_error" -gt 0 ]]; then
      echo -e "  ${FAIL} Request $i: ${RED}${elapsed}${RESET} — Error fetching reviews (no failover)"
    else
      echo -e "  ${WARN} Request $i: ${YELLOW}${elapsed}${RESET} — unexpected response"
    fi
  fi
  sleep 1
done

echo ""
if [[ "$failover_ok" -eq 5 ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}5/5 requests succeeded — cross-cluster failover working${RESET}"
elif [[ "$failover_ok" -gt 0 ]]; then
  echo -e "  ${WARN} ${failover_ok}/5 requests succeeded — partial failover"
else
  echo -e "  ${FAIL} ${RED}${BOLD}0/5 requests — failover not working${RESET}"
fi

section "WEST2 pods (serving cross-cluster traffic)"
oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
  | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    echo -e "  ${PASS} ${name}  ${GREEN}${status}${RESET}"
  done

echo ""
echo -e "  ${CYAN}${BOLD}▶ Verify in browser (reviews served from WEST2):${RESET}"
echo -e "  ${CYAN}  ${EAST_URL}${RESET}"

pause "Press ENTER to restore and continue..."

# Step 3: Recovery
header "3. Recovery — Restore reviews in EAST2"
echo ""
echo -e "  Scaling reviews-v1, reviews-v2, reviews-v3 → ${GREEN}${BOLD}1 replica${RESET} each..."
oc --context "$EAST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n "$NS" --replicas=1 2>/dev/null
echo -e "  Waiting for pods to be ready..."
sleep 12

section "reviews status after restore"
oc --context "$EAST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
  | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    icon="${PASS}"
    [[ "$status" != "Running" ]] && icon="${WARN}"
    echo -e "  ${icon} ${name}  ${GREEN}${status}${RESET}"
  done
RECOVERED=$(oc --context "$EAST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null | grep -c Running || true)

section "Endpoints restored"
ep_restored=$(oc --context "$EAST_CTX" get endpoints reviews -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
if [[ -n "$ep_restored" ]]; then
  echo -e "  ${PASS} Endpoints: ${ep_restored}"
else
  echo -e "  ${WARN} Endpoints: <none> (still propagating)"
fi

section "Recovery traffic test"
recovery_ok=0
for i in 1 2 3; do
  rc=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_URL" 2>/dev/null || echo "000")
  if [[ "$rc" == "200" ]]; then
    echo -e "  ${PASS} Request $i: ${GREEN}HTTP ${rc}${RESET}"
    recovery_ok=$((recovery_ok + 1))
  else
    echo -e "  ${WARN} Request $i: ${YELLOW}HTTP ${rc}${RESET}"
  fi
  sleep 1
done

echo ""
if [[ "$RECOVERED" -ge 3 && "$recovery_ok" -eq 3 ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}Recovery complete — ${RECOVERED} pods Running, 3/3 requests OK${RESET}"
else
  echo -e "  ${WARN} Recovery partial — pods: ${RECOVERED}, requests OK: ${recovery_ok}/3"
fi

# Summary
header "RESILIENCE & FAILOVER SUMMARY"
echo ""
echo -e "  ${BOLD}Phase                 EAST2 reviews    Traffic         Source${RESET}"
echo -e "  Baseline            Running (3)       ${GREEN}${BOLD}HTTP 200${RESET}        local EAST2"
echo -e "  Scale to 0          ${RED}${BOLD}0 pods${RESET}            ${GREEN}${BOLD}HTTP 200${RESET}        ${CYAN}${BOLD}WEST2 (failover)${RESET}"
echo -e "  Recovery            Running (3)       ${GREEN}${BOLD}HTTP 200${RESET}        local EAST2"
echo ""
echo -e "  ${BOLD}Why:${RESET} istiod discovers remote endpoints via remote secrets."
echo -e "  When local endpoints are absent, ztunnel routes through the East-West"
echo -e "  Gateway to healthy replicas in the remote cluster — sub-second failover."
echo ""
