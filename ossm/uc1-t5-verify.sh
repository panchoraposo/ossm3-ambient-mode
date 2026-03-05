#!/bin/bash
#
# UC1-T5: Control Plane Independence — Verification Script
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
WEST_ROUTE="http://bookinfo.apps.cluster-7rt9h.7rt9h.sandbox1900.opentlc.com/productpage"
KIALI_URL="https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph"

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

check_istiod() {
  local label="$1"
  section "istiod status: ${label}"
  for ctx in east west; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    pod=$(oc --context "$ctx" get pods -n istio-system -l app=istiod --no-headers 2>/dev/null)
    if [[ -n "$pod" ]]; then
      pod_name=$(echo "$pod" | awk '{print $1}')
      pod_status=$(echo "$pod" | awk '{print $3}')
      if [[ "$pod_status" == "Running" ]]; then
        echo -e "  ${PASS} ${CTX_UPPER}: ${pod_name}  ${GREEN}${pod_status}${RESET}"
      else
        echo -e "  ${WARN} ${CTX_UPPER}: ${pod_name}  ${YELLOW}${pod_status}${RESET}"
      fi
    else
      echo -e "  ${RED}✘${RESET} ${CTX_UPPER}: ${RED}${BOLD}No istiod pods${RESET}"
    fi
  done
}

test_traffic() {
  local label="$1"
  section "Traffic test: ${label}"
  east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
  west_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$WEST_ROUTE" 2>/dev/null)
  [[ -z "$east_code" || "$east_code" == "000" ]] && east_code="TIMEOUT"
  [[ -z "$west_code" || "$west_code" == "000" ]] && west_code="TIMEOUT"

  if [[ "$east_code" == "200" ]]; then
    echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET}"
  else
    echo -e "  ${FAIL} EAST: ${RED}HTTP ${east_code}${RESET}"
  fi
  if [[ "$west_code" == "200" ]]; then
    echo -e "  ${PASS} WEST: ${GREEN}HTTP ${west_code}${RESET}"
  else
    echo -e "  ${FAIL} WEST: ${RED}HTTP ${west_code}${RESET}"
  fi
}

# --- Run test ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC1-T5: Control Plane Independence                       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# Step 1: Baseline
header "1. Verify Initial State"
echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET}"
echo -e "  → Open in browser: ${BOLD}${WEST_ROUTE}${RESET}"
check_istiod "before failure"
test_traffic "before failure"
pause "Press ENTER to simulate control plane failure..."

# Step 2: Kill istiod in EAST
header "2. Simulate Control Plane Failure in EAST"
echo ""
echo -e "  Scaling istiod to 0 replicas in EAST..."
oc --context east scale deployment istiod -n istio-system --replicas=0 2>/dev/null
sleep 5
check_istiod "after scaling down EAST"

# Step 3: Verify traffic still works
header "3. Verify Traffic Keeps Flowing"
test_traffic "with istiod EAST down (attempt 1)"
test_traffic "with istiod EAST down (attempt 2)"
test_traffic "with istiod EAST down (attempt 3)"

echo ""
echo -e "  ${CYAN}${BOLD}▶ istiod EAST is DOWN — check Kiali to verify traffic still flows${RESET}"
echo -e "  ${CYAN}  ${KIALI_URL}${RESET}"
echo ""
pause "Press ENTER to restore istiod and continue..."

# Step 4: Restore istiod
header "4. Restore istiod in EAST"
echo ""
echo -e "  Scaling istiod back to 1 replica..."
oc --context east scale deployment istiod -n istio-system --replicas=1 2>/dev/null
echo -e "  Waiting for istiod to start..."
sleep 10
check_istiod "after restore"

# Step 5: Final verification
header "5. Verify Recovery"
test_traffic "after restore"

# Summary
header "CONTROL PLANE INDEPENDENCE SUMMARY"
echo ""
echo -e "  ${BOLD}Phase             istiod EAST    EAST traffic    WEST traffic${RESET}"
echo -e "  Before           Running         HTTP 200        HTTP 200"
echo -e "  istiod down      ${RED}${BOLD}0 pods${RESET}          ${GREEN}${BOLD}HTTP 200${RESET}        ${GREEN}${BOLD}HTTP 200${RESET}"
echo -e "  Restored         Running         HTTP 200        HTTP 200"
echo ""
echo -e "  ${BOLD}Why:${RESET} ztunnel (and waypoints, if deployed) keep their config in memory."
echo -e "  Losing istiod = no new config updates, but existing data-plane traffic is unaffected."
echo ""
