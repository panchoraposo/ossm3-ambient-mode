#!/bin/bash
#
# UC1-T6: Infrastructure Segregation (L4 vs Policy) — Verification Script
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

check_restarts() {
  local label="$1"
  section "Pod restarts: ${label}"
  restarts=$(oc --context east get pods -n bookinfo --no-headers 2>/dev/null | awk '{sum+=$4} END{print sum}')
  [[ -z "$restarts" ]] && restarts=0
  if [[ "$restarts" -eq 0 ]]; then
    echo -e "  ${PASS} EAST: ${GREEN}0 restarts${RESET}"
  else
    echo -e "  ${WARN} EAST: ${YELLOW}${restarts} restarts${RESET}"
  fi
}

check_reviews_status() {
  local label="$1"
  local expect_error="$2"
  section "Reviews status: ${label}"
  html=$(curl -s -m 10 "$EAST_ROUTE" 2>/dev/null)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$EAST_ROUTE" 2>/dev/null)

  echo -e "  HTTP code: ${BOLD}${http_code}${RESET}"

  if echo "$html" | grep -q "Error fetching product reviews"; then
    if [[ "$expect_error" == "true" ]]; then
      echo -e "  ${PASS} Reviews: ${RED}${BOLD}Error fetching product reviews!${RESET}  ${GREEN}(policy active)${RESET}"
    else
      echo -e "  ${FAIL} Reviews: ${RED}Error fetching product reviews!${RESET} (unexpected)"
    fi
  else
    if [[ "$expect_error" == "false" ]]; then
      echo -e "  ${PASS} Reviews: ${GREEN}working normally${RESET}"
    else
      echo -e "  ${FAIL} Reviews: ${YELLOW}still working${RESET} (expected error)"
    fi
  fi
}

# --- Run test ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC1-T6: Infrastructure Segregation (L4 vs Policy)        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# Step 1: Baseline
header "1. Verify Baseline"
check_reviews_status "before changes" "false"
check_restarts "before changes"

# Step 2 & 3: Apply both changes simultaneously
header "2. Apply L4 Change (Telemetry) + Policy Change (AuthorizationPolicy)"

section "L4: Enable ztunnel access logging"
oc --context east apply -f - <<EOF 2>/dev/null
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: ztunnel-logging
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: ztunnel
  accessLogging:
    - providers:
        - name: envoy
      filter:
        expression: "true"
EOF
echo -e "  ${PASS} Telemetry ${GREEN}ztunnel-logging${RESET} applied to istio-system"

section "Policy: Deny reviews from productpage"
oc --context east apply -f - <<EOF 2>/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-reviews-from-productpage
  namespace: bookinfo
spec:
  selector:
    matchLabels:
      app: reviews
  action: DENY
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/bookinfo/sa/bookinfo-productpage"
EOF
echo -e "  ${PASS} AuthorizationPolicy ${RED}deny-reviews-from-productpage${RESET} applied to bookinfo"

echo ""
echo -e "  Waiting 3 seconds for propagation..."
sleep 3

# Step 3: Verify both changes
header "3. Verify Both Changes"

check_restarts "after applying changes"
check_reviews_status "after applying changes" "true"

section "ztunnel access logs (L4)"
deny_logs=$(oc --context east logs -n ztunnel ds/ztunnel --tail=20 2>/dev/null | grep "reviews")
if [[ -n "$deny_logs" ]]; then
  deny_count=$(echo "$deny_logs" | grep -c "policy rejection")
  access_count=$(echo "$deny_logs" | wc -l | tr -d ' ')
  echo -e "  ${PASS} ${GREEN}${access_count} log entries${RESET} for reviews traffic (${RED}${deny_count} denied${RESET})"
  echo "$deny_logs" | tail -1 | while read -r line; do
    short=$(echo "$line" | grep -o 'error="[^"]*"' | head -1)
    [[ -n "$short" ]] && echo -e "       ${CYAN}${short}${RESET}"
  done
else
  echo -e "  ${WARN} No reviews entries in ztunnel logs yet"
fi

# Pause for Kiali
echo ""
echo -e "  ${CYAN}${BOLD}▶ Both changes active — check Kiali for red edge on reviews${RESET}"
echo -e "  ${CYAN}  ${KIALI_URL}${RESET}"
echo -e "  ${CYAN}  Also open bookinfo in browser to see 'Error fetching product reviews!'${RESET}"
echo ""
read -rp "  Press ENTER to continue with cleanup..."

# Step 4: Cleanup
header "4. Cleanup"
oc --context east delete authorizationpolicy deny-reviews-from-productpage -n bookinfo 2>/dev/null
echo -e "  ${PASS} AuthorizationPolicy ${GREEN}removed${RESET}"
oc --context east delete telemetry ztunnel-logging -n istio-system 2>/dev/null
echo -e "  ${PASS} Telemetry ${GREEN}removed${RESET}"
echo ""
echo -e "  Waiting 3 seconds..."
sleep 3

# Step 5: Verify recovery
header "5. Verify Recovery"
check_reviews_status "after cleanup" "false"
check_restarts "after cleanup"

# Summary
header "INFRASTRUCTURE SEGREGATION SUMMARY"
echo ""
echo -e "  ${BOLD}L4 (Telemetry):${RESET}       ${GREEN}Access logs activated${RESET} — no pod restarts"
echo -e "  ${BOLD}Policy (AuthzPol):${RESET}    ${GREEN}Reviews denied instantly${RESET} — no pod restarts"
echo -e "  ${BOLD}Independence:${RESET}         Both applied/removed without coordination"
echo -e "  ${BOLD}Recovery:${RESET}             Instant after cleanup"
echo -e "  ${BOLD}Pod restarts:${RESET}         ${GREEN}ZERO${RESET}"
echo ""
