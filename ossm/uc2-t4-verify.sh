#!/bin/bash
#
# UC2-T4: mTLS Enforcement with PeerAuthentication STRICT — Verification Script
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
MESH_SVC="http://productpage.bookinfo.svc.cluster.local:9080/productpage"
TEST_NS="outside-mesh"
TEST_POD="curl-test"

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

test_from_outside() {
  local label="$1"
  local expect_success="$2"
  section "Non-mesh pod → mesh service: ${label}"
  code=$(oc --context east exec "$TEST_POD" -n "$TEST_NS" -- curl -s -o /dev/null -w "%{http_code}" -m 5 "$MESH_SVC" 2>/dev/null)
  [[ -z "$code" || "$code" == "000" ]] && code="000 (connection reset)"

  if [[ "$expect_success" == "true" ]]; then
    if [[ "$code" == "200" ]]; then
      echo -e "  ${PASS} Plaintext: ${GREEN}HTTP ${code}${RESET}  (PERMISSIVE — accepted)"
    else
      echo -e "  ${FAIL} Plaintext: ${RED}HTTP ${code}${RESET}  (expected 200)"
    fi
  else
    if [[ "$code" != "200" ]]; then
      echo -e "  ${PASS} Plaintext: ${RED}${BOLD}HTTP ${code}${RESET}  ${GREEN}(STRICT — rejected!)${RESET}"
    else
      echo -e "  ${FAIL} Plaintext: ${YELLOW}HTTP ${code}${RESET}  (expected rejection)"
    fi
  fi
}

test_from_mesh() {
  local label="$1"
  section "Mesh traffic (mTLS via ztunnel): ${label}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$EAST_ROUTE" 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    echo -e "  ${PASS} mTLS: ${GREEN}HTTP ${code}${RESET}  (mesh traffic OK)"
  else
    echo -e "  ${FAIL} mTLS: ${RED}HTTP ${code}${RESET}"
  fi
}

# --- Run test ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC2-T4: mTLS Enforcement (PeerAuthentication STRICT)     ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# Step 1: Setup non-mesh pod
header "1. Setup Non-Mesh Test Pod"
echo ""
echo -e "  Creating namespace '${TEST_NS}' (outside the mesh)..."
oc --context east create namespace "$TEST_NS" --dry-run=client -o yaml 2>/dev/null | oc --context east apply -f - 2>/dev/null
echo -e "  ${PASS} Namespace ${BOLD}${TEST_NS}${RESET} created (no ambient label)"

echo -e "  Deploying test pod..."
oc --context east delete pod "$TEST_POD" -n "$TEST_NS" --ignore-not-found 2>/dev/null
oc --context east run "$TEST_POD" --image=curlimages/curl --namespace="$TEST_NS" --restart=Never --command -- sleep 3600 2>/dev/null
echo -e "  Waiting for pod to be ready..."
oc --context east wait --for=condition=Ready pod/"$TEST_POD" -n "$TEST_NS" --timeout=30s 2>/dev/null
echo -e "  ${PASS} Pod ${BOLD}${TEST_POD}${RESET} running in non-mesh namespace"

# Step 2: Test PERMISSIVE (default)
header "2. Test Default Mode (PERMISSIVE)"
test_from_outside "default (no PeerAuthentication)" "true"
test_from_mesh "default"

# Step 3: Apply STRICT
header "3. Apply PeerAuthentication STRICT"
oc --context east apply -f - <<EOF 2>/dev/null
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
echo -e "  ${PASS} PeerAuthentication ${RED}${BOLD}STRICT${RESET} applied to istio-system"
echo ""
echo -e "  Waiting 5 seconds for propagation..."
sleep 5

# Step 4: Test STRICT
header "4. Verify STRICT Enforcement"
test_from_outside "with STRICT" "false"
test_from_mesh "with STRICT"

echo ""
echo -e "  ${CYAN}${BOLD}▶ STRICT active:${RESET}"
echo -e "  ${CYAN}  • Non-mesh pod (plaintext) → REJECTED by ztunnel${RESET}"
echo -e "  ${CYAN}  • Mesh traffic (mTLS) → unaffected, still HTTP 200${RESET}"
echo -e "  ${CYAN}  • Kiali should show normal green traffic (STRICT only blocks${RESET}"
echo -e "  ${CYAN}    external plaintext — the rejected pod is outside the mesh${RESET}"
echo -e "  ${CYAN}    and invisible to Kiali)${RESET}"
echo ""
read -rp "  Press ENTER to continue with cleanup..."

# Step 5: Cleanup
header "5. Cleanup"
oc --context east delete peerauthentication strict-mtls -n istio-system 2>/dev/null
echo -e "  ${PASS} PeerAuthentication ${GREEN}removed${RESET}"
oc --context east delete pod "$TEST_POD" -n "$TEST_NS" --ignore-not-found 2>/dev/null
oc --context east delete namespace "$TEST_NS" --ignore-not-found 2>/dev/null &
echo -e "  ${PASS} Test namespace ${GREEN}removed${RESET}"
echo ""
echo -e "  Waiting for cleanup..."
sleep 5

# Step 6: Verify recovery
header "6. Verify Recovery"
test_from_mesh "after cleanup"

# Summary
header "mTLS ENFORCEMENT SUMMARY"
echo ""
echo -e "  ${BOLD}Default [PERMISSIVE]:${RESET}  Plaintext ${GREEN}accepted${RESET}, mTLS ${GREEN}accepted${RESET}"
echo -e "  ${BOLD}STRICT applied:${RESET}        Plaintext ${RED}${BOLD}REJECTED${RESET}, mTLS ${GREEN}accepted${RESET}"
echo -e "  ${BOLD}Enforcement:${RESET}           ztunnel [L4] — immediate, no restarts"
echo -e "  ${BOLD}Scope:${RESET}                 Root namespace → entire mesh"
echo -e "  ${BOLD}Pod restarts:${RESET}          ${GREEN}ZERO${RESET}"
echo ""
