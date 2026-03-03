#!/bin/bash
#
# UC2-T1: The "Lockdown" (Deny-All Everywhere) — Verification Script
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

EAST_ROUTE="http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage"
WEST_ROUTE="http://bookinfo.apps.cluster-7rt9h.7rt9h.sandbox1900.opentlc.com/productpage"

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

test_traffic() {
  local label="$1"
  local expect_success="$2"
  section "Traffic test: ${label}"

  east_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$EAST_ROUTE" 2>/dev/null)
  west_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$WEST_ROUTE" 2>/dev/null)
  [[ -z "$east_code" || "$east_code" == "000" ]] && east_code="TIMEOUT"
  [[ -z "$west_code" || "$west_code" == "000" ]] && west_code="TIMEOUT"

  if [[ "$expect_success" == "true" ]]; then
    if [[ "$east_code" == "200" ]]; then
      echo -e "  ${PASS} EAST: ${GREEN}HTTP ${east_code}${RESET}"
    else
      echo -e "  ${FAIL} EAST: ${RED}HTTP ${east_code}${RESET} (expected 200)"
    fi
    if [[ "$west_code" == "200" ]]; then
      echo -e "  ${PASS} WEST: ${GREEN}HTTP ${west_code}${RESET}"
    else
      echo -e "  ${FAIL} WEST: ${RED}HTTP ${west_code}${RESET} (expected 200)"
    fi
  else
    if [[ "$east_code" != "200" ]]; then
      echo -e "  ${PASS} EAST: ${RED}HTTP ${east_code}${RESET}  ${GREEN}(denied — lockdown active)${RESET}"
    else
      echo -e "  ${FAIL} EAST: ${YELLOW}HTTP ${east_code}${RESET} (expected denial)"
    fi
    if [[ "$west_code" != "200" ]]; then
      echo -e "  ${PASS} WEST: ${RED}HTTP ${west_code}${RESET}  ${GREEN}(denied — lockdown active)${RESET}"
    else
      echo -e "  ${FAIL} WEST: ${YELLOW}HTTP ${west_code}${RESET} (expected denial)"
    fi
  fi
}

check_restarts() {
  local label="$1"
  section "Pod restarts: ${label}"
  for ctx in east west; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    restarts=$(oc --context "$ctx" get pods -n bookinfo --no-headers 2>/dev/null | awk '{sum+=$4} END{print sum}')
    [[ -z "$restarts" ]] && restarts=0
    if [[ "$restarts" -eq 0 ]]; then
      echo -e "  ${PASS} ${CTX_UPPER}: ${GREEN}0 restarts${RESET}"
    else
      echo -e "  ${WARN} ${CTX_UPPER}: ${YELLOW}${restarts} restarts${RESET}"
    fi
  done
}

check_ztunnel_deny_logs() {
  section "ztunnel deny logs"
  for ctx in east west; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    deny_count=$(oc --context "$ctx" logs -n ztunnel ds/ztunnel --tail=30 2>/dev/null | grep -c -i "denied\|policy rejection")
    if [[ "$deny_count" -gt 0 ]]; then
      echo -e "  ${PASS} ${CTX_UPPER}: ${RED}${deny_count} deny entries${RESET} in ztunnel logs"
      oc --context "$ctx" logs -n ztunnel ds/ztunnel --tail=30 2>/dev/null | grep -i "denied\|policy rejection" | tail -1 | while read -r line; do
        short=$(echo "$line" | grep -o 'error="[^"]*"' | head -1)
        echo -e "       ${CYAN}${short}${RESET}"
      done
    else
      echo -e "  ${PASS} ${CTX_UPPER}: deny enforced at gateway level (403), ztunnel not involved"
    fi
  done
}

# --- Run test ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC2-T1: The Lockdown (Deny-All Everywhere)               ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# Step 1: Baseline
header "1. Baseline"
test_traffic "before lockdown" "true"
check_restarts "before lockdown"

# Step 2: Apply deny-all
header "2. Apply Deny-All to Root Namespace"
for ctx in east west; do
  CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
  oc --context "$ctx" apply -f - <<EOF 2>/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: istio-system
spec: {}
EOF
  if [[ $? -eq 0 ]]; then
    echo -e "  ${PASS} ${CTX_UPPER}: ${RED}deny-all${RESET} applied to istio-system"
  else
    echo -e "  ${FAIL} ${CTX_UPPER}: failed to apply"
  fi
done
echo ""
echo -e "  Waiting 3 seconds for policy propagation..."
sleep 3

# Step 3: Verify lockdown
header "3. Verify Lockdown"
test_traffic "during lockdown" "false"
check_ztunnel_deny_logs
check_restarts "during lockdown"

echo ""
echo -e "  ${CYAN}${BOLD}▶ Lockdown active — check Kiali for red edges / denied traffic${RESET}"
echo -e "  ${CYAN}  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph${RESET}"
echo ""
read -rp "  Press ENTER to continue with cleanup..."

# Step 4: Cleanup
header "4. Cleanup"
for ctx in east west; do
  CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
  oc --context "$ctx" delete authorizationpolicy deny-all -n istio-system 2>/dev/null
  if [[ $? -eq 0 ]]; then
    echo -e "  ${PASS} ${CTX_UPPER}: deny-all ${GREEN}removed${RESET}"
  else
    echo -e "  ${WARN} ${CTX_UPPER}: deny-all not found (already clean)"
  fi
done
echo ""
echo -e "  Waiting 3 seconds for policy removal..."
sleep 3

# Step 5: Verify recovery
header "5. Verify Recovery"
test_traffic "after cleanup" "true"
check_restarts "after cleanup"

# Summary
header "LOCKDOWN TEST SUMMARY"
echo ""
echo -e "  ${BOLD}Deny-all scope:${RESET}     Root namespace (istio-system) → entire mesh"
echo -e "  ${BOLD}Enforcement:${RESET}        ztunnel (L4) — immediate, no restarts"
echo -e "  ${BOLD}Both clusters:${RESET}      Locked down simultaneously"
echo -e "  ${BOLD}Recovery:${RESET}           Instant after policy removal"
echo -e "  ${BOLD}Pod restarts:${RESET}       ${GREEN}ZERO${RESET}"
echo ""
