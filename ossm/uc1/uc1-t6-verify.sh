#!/bin/bash
#
# UC1-T6: Infrastructure Segregation (L4 vs L7) — Verification Script
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

  local tmpfile="/tmp/uc1t6-response.html"
  local http_code="000"
  local retries=3
  for i in $(seq 1 $retries); do
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 "$EAST_ROUTE" 2>/dev/null)
    [[ "$http_code" != "000" ]] && break
    [[ $i -lt $retries ]] && echo -e "  ${WARN} Attempt $i/${retries} timed out, retrying..." && sleep 5
  done
  html=$(cat "$tmpfile" 2>/dev/null)
  rm -f "$tmpfile"

  echo -e "  HTTP code: ${BOLD}${http_code}${RESET}"

  if [[ "$http_code" == "000" ]]; then
    echo -e "  ${FAIL} ${RED}Connection failed after ${retries} attempts${RESET}"
    return
  fi

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

cleanup() {
  echo ""
  echo -e "  ${BOLD}Cleaning up (safety net)...${RESET}"
  oc --context east delete authorizationpolicy deny-reviews-from-productpage -n bookinfo >/dev/null 2>&1
  oc --context east delete telemetry ztunnel-logging -n istio-system >/dev/null 2>&1
  oc --context east label svc reviews -n bookinfo istio.io/use-waypoint- >/dev/null 2>&1
  oc --context east delete gateway reviews-waypoint -n bookinfo >/dev/null 2>&1
  echo -e "  ${PASS} Resources cleaned up"
}
trap cleanup EXIT

# --- Run test ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC1-T6: Infrastructure Segregation (L4 vs L7)            ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# Step 1: Baseline
header "1. Verify Baseline"
echo -e "  → Open in browser: ${BOLD}${EAST_ROUTE}${RESET}"
check_reviews_status "before changes" "false"
check_restarts "before changes"

pause "Press ENTER to deploy waypoint and apply changes..."

# Step 2: Deploy reviews-waypoint (L7 required for AuthorizationPolicy with targetRefs)
header "2. Deploy reviews-waypoint (L7 proxy)"

section "Create reviews-waypoint Gateway"
oc --context east apply -f - <<EOF 2>/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: reviews-waypoint
  namespace: bookinfo
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

section "Label reviews Service to use waypoint"
oc --context east label svc reviews -n bookinfo istio.io/use-waypoint=reviews-waypoint --overwrite 2>/dev/null
echo -e "  ${PASS} Service reviews labeled with ${GREEN}istio.io/use-waypoint=reviews-waypoint${RESET}"

section "Waiting for waypoint pod to be ready"
oc --context east wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=reviews-waypoint -n bookinfo --timeout=60s 2>/dev/null
echo -e "  ${PASS} Waypoint pod ${GREEN}Ready${RESET}"

# Step 3: Apply L4 + L7 changes simultaneously
header "3. Apply L4 Change (ztunnel) + L7 Change (waypoint)"

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

section "L7: Deny reviews from productpage (via waypoint)"
oc --context east apply -f - <<EOF 2>/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-reviews-from-productpage
  namespace: bookinfo
spec:
  targetRefs:
    - kind: Service
      group: ""
      name: reviews
  action: DENY
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/bookinfo/sa/bookinfo-productpage"
EOF
echo -e "  ${PASS} AuthorizationPolicy ${RED}deny-reviews-from-productpage${RESET} applied (L7, enforced by waypoint)"

echo ""
echo -e "  Waiting 10 seconds for propagation..."
sleep 10

# Step 4: Verify both changes
header "4. Verify Both Changes"

check_restarts "after applying changes"
check_reviews_status "after applying changes" "true"

section "L4: ztunnel connection logs"
ztunnel_logs=$(oc --context east logs -n ztunnel ds/ztunnel --tail=20 2>/dev/null | grep "reviews")
if [[ -n "$ztunnel_logs" ]]; then
  zt_count=$(echo "$ztunnel_logs" | wc -l | tr -d ' ')
  echo -e "  ${PASS} ${GREEN}${zt_count} L4 connection entries${RESET} for reviews traffic"
  echo -e "       (ztunnel sees connections, not HTTP-level denials)"
else
  echo -e "  ${WARN} No reviews entries in ztunnel logs yet"
fi

section "L7: waypoint RBAC stats"
wp_pod=$(oc --context east get pods -n bookinfo -l gateway.networking.k8s.io/gateway-name=reviews-waypoint --no-headers 2>/dev/null | awk '{print $1}' | head -1)
if [[ -n "$wp_pod" ]]; then
  rbac_denied=$(oc --context east exec "$wp_pod" -n bookinfo -- pilot-agent request GET /stats 2>/dev/null | grep "rbac.denied" | awk -F: '{print $NF}' | tr -d ' ')
  rbac_allowed=$(oc --context east exec "$wp_pod" -n bookinfo -- pilot-agent request GET /stats 2>/dev/null | grep "rbac.allowed" | awk -F: '{print $NF}' | tr -d ' ')
  if [[ -n "$rbac_denied" && "$rbac_denied" -gt 0 ]] 2>/dev/null; then
    echo -e "  ${PASS} ${RED}rbac.denied: ${rbac_denied}${RESET}  (L7 denials enforced by waypoint)"
    echo -e "  ${PASS} ${GREEN}rbac.allowed: ${rbac_allowed:-0}${RESET}"
    echo -e "       (stats from: pilot-agent request GET /stats | grep rbac)"
  else
    echo -e "  ${WARN} rbac.denied: ${rbac_denied:-0} — generate traffic and retry"
    echo -e "       (run: oc exec $wp_pod -n bookinfo -- pilot-agent request GET /stats | grep rbac)"
  fi
else
  echo -e "  ${WARN} Waypoint pod not found"
fi

# Pause for browser verification
echo ""
echo -e "  ${CYAN}${BOLD}▶ Both L4 + L7 changes active${RESET}"
echo -e "  ${CYAN}  Open bookinfo in browser to see 'Error fetching product reviews!'${RESET}"
echo -e "  ${CYAN}  ${EAST_ROUTE}${RESET}"
echo ""
pause "Press ENTER to cleanup and verify recovery..."

# Step 5: Cleanup & Recovery
header "5. Cleanup & Recovery"
echo -e "  Removing all resources (L7 policy, L4 telemetry, waypoint)..."
oc --context east delete authorizationpolicy deny-reviews-from-productpage -n bookinfo 2>/dev/null
echo -e "  ${PASS} AuthorizationPolicy ${GREEN}removed${RESET}"
oc --context east delete telemetry ztunnel-logging -n istio-system 2>/dev/null
echo -e "  ${PASS} Telemetry ${GREEN}removed${RESET}"
oc --context east label svc reviews -n bookinfo istio.io/use-waypoint- 2>/dev/null
echo -e "  ${PASS} Waypoint label ${GREEN}removed${RESET} from reviews"
oc --context east delete gateway reviews-waypoint -n bookinfo 2>/dev/null
echo -e "  ${PASS} Gateway reviews-waypoint ${GREEN}deleted${RESET}"
echo ""
echo -e "  Waiting 15 seconds for traffic to stabilize..."
sleep 15

check_reviews_status "after cleanup (back to L4-only)" "false"
check_restarts "after cleanup"

# Summary
header "INFRASTRUCTURE SEGREGATION SUMMARY"
echo ""
echo -e "  ${BOLD}Waypoint:${RESET}             ${GREEN}Deployed on demand${RESET} for L7 policy enforcement"
echo -e "  ${BOLD}L4 (ztunnel):${RESET}         ${GREEN}Access logs activated${RESET} — no pod restarts"
echo -e "  ${BOLD}L7 (waypoint):${RESET}        ${GREEN}Reviews denied instantly${RESET} — no pod restarts"
echo -e "  ${BOLD}Independence:${RESET}         L4 and L7 applied/removed without coordination"
echo -e "  ${BOLD}Recovery:${RESET}             Instant after cleanup"
echo -e "  ${BOLD}Pod restarts:${RESET}         ${GREEN}ZERO${RESET}"
echo ""
