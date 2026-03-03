#!/bin/bash
set +o posix
#
# morning-check.sh — Post-restart recovery for OSSM 3.2 PoC clusters
#
# After sandbox clusters (EAST/WEST) restart overnight, bookinfo pods
# retain stale iptables rules and ztunnel cannot deliver inbound HBONE.
# This script restarts bookinfo workloads and verifies external access.
#

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

PASS="${GREEN}✔${RESET}"
FAIL="${RED}✘${RESET}"

EAST_ROUTE="bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com"
WEST_ROUTE="bookinfo.apps.cluster-7rt9h.7rt9h.sandbox1900.opentlc.com"

ERRORS=0

header() {
  echo ""
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

step() {
  echo ""
  echo -e "${BOLD}▸ $1${RESET}"
}

# ── 1. Cluster connectivity ──────────────────────────────────────────

header "MORNING CHECK — $(date '+%Y-%m-%d %H:%M')"

step "Checking cluster connectivity"

for ctx in acm east west; do
  CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
  if oc --context "$ctx" cluster-info &>/dev/null; then
    echo -e "  ${PASS} ${CTX_UPPER} reachable"
  else
    echo -e "  ${FAIL} ${CTX_UPPER} unreachable — aborting"
    exit 1
  fi
done

# ── 2. Rollout restart bookinfo ──────────────────────────────────────

step "Restarting bookinfo pods (EAST & WEST)"

for ctx in east west; do
  CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
  oc --context "$ctx" -n bookinfo rollout restart deployment &>/dev/null
  echo -e "  ${PASS} ${CTX_UPPER} rollout restart triggered"
done

# ── 3. Wait for pods ─────────────────────────────────────────────────

step "Waiting for all pods to be Ready"

for ctx in east west; do
  CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
  DEPLOYMENTS=$(oc --context "$ctx" get deployments -n bookinfo -o jsonpath='{.items[*].metadata.name}')
  ALL_OK=true
  for dep in $DEPLOYMENTS; do
    if ! oc --context "$ctx" -n bookinfo rollout status deployment/"$dep" --timeout=120s &>/dev/null; then
      echo -e "  ${FAIL} ${CTX_UPPER} ${dep} did not become Ready"
      ALL_OK=false
      ERRORS=$((ERRORS + 1))
    fi
  done
  if $ALL_OK; then
    POD_COUNT=$(oc --context "$ctx" get pods -n bookinfo --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${PASS} ${CTX_UPPER} all deployments ready (${POD_COUNT} pods running)"
  fi
done

# ── 4. Test external HTTP access ─────────────────────────────────────

step "Testing external HTTP access"

sleep 5

for entry in "east|${EAST_ROUTE}" "west|${WEST_ROUTE}"; do
  ctx="${entry%%|*}"
  route="${entry##*|}"
  CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "http://${route}/productpage" 2>/dev/null)

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "  ${PASS} ${CTX_UPPER} http://${route}/productpage → HTTP ${HTTP_CODE}"
  else
    echo -e "  ${FAIL} ${CTX_UPPER} http://${route}/productpage → HTTP ${HTTP_CODE}"
    ERRORS=$((ERRORS + 1))
  fi
done

# ── 5. Summary ───────────────────────────────────────────────────────

header "RESULT"

if [[ $ERRORS -eq 0 ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}All checks passed — environment is ready${RESET}"
else
  echo -e "  ${FAIL} ${RED}${BOLD}${ERRORS} check(s) failed — review output above${RESET}"
fi
echo ""
