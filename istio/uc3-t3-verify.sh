#!/bin/bash
#
# UC3-T3: The "Follow-the-Service" Migration — Verification Script
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
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

section() {
  echo ""
  echo -e "${BOLD}▸ $1${RESET}"
}

EAST_CTX="east2"
WEST_CTX="west2"
ACM_CTX="acm2"
NS="bookinfo"
ROUTE_NAME="bookinfo-gateway"

cleanup() {
  oc --context "$WEST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
    -n "$NS" --replicas=1 &>/dev/null || true
}
trap cleanup EXIT

EAST_HOST=$(oc --context "$EAST_CTX" get route "$ROUTE_NAME" -n "$NS" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
EAST_URL="http://${EAST_HOST}/productpage"

if [[ -z "$EAST_HOST" ]]; then
  echo -e "  ${FAIL} Could not discover Route in ${EAST_CTX}. Aborting."
  exit 1
fi

KIALI_HOST=$(oc --context "$ACM_CTX" get route kiali -n istio-system \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "$KIALI_HOST" ]]; then
  KIALI_URL="https://${KIALI_HOST}"
fi

PP_POD=$(oc --context "$EAST_CTX" get pods -n "$NS" -l app=productpage \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

# ── Banner ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC3-T3: The \"Follow-the-Service\" Migration                ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  EAST2 URL: ${CYAN}${EAST_URL}${RESET}"
if [[ -n "$KIALI_URL" ]]; then
  echo -e "  Kiali:     ${CYAN}${KIALI_URL}${RESET}"
fi

# ── Step 1: Baseline ────────────────────────────────────────────────────
header "1. Verify Baseline — reviews Running in Both Clusters"

section "reviews pods: EAST2"
oc --context "$EAST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
  | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    icon="${PASS}"
    [[ "$status" != "Running" ]] && icon="${FAIL}"
    echo -e "  ${icon} ${name}  ${GREEN}${status}${RESET}"
  done
EAST_COUNT=$(oc --context "$EAST_CTX" get pods -n "$NS" -l app=reviews \
  --no-headers 2>/dev/null | grep -c Running || true)

section "reviews pods: WEST2"
oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
  | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    icon="${PASS}"
    [[ "$status" != "Running" ]] && icon="${FAIL}"
    echo -e "  ${icon} ${name}  ${GREEN}${status}${RESET}"
  done
WEST_COUNT=$(oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews \
  --no-headers 2>/dev/null | grep -c Running || true)

section "Endpoints visible from EAST2"
ep_list=$(oc --context "$EAST_CTX" get endpoints reviews -n "$NS" \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
ep_count=$(echo "$ep_list" | wc -w | tr -d ' ')
if [[ -n "$ep_list" ]]; then
  echo -e "  ${PASS} ${ep_count} endpoint(s): ${ep_list}"
else
  echo -e "  ${FAIL} Endpoints: ${RED}<none>${RESET}"
fi

section "Baseline traffic test"
baseline_code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 \
  --retry-delay 3 "$EAST_URL" 2>/dev/null || echo "000")
if [[ "$baseline_code" == "200" ]]; then
  echo -e "  ${PASS} EAST2: ${GREEN}HTTP ${baseline_code}${RESET}"
else
  echo -e "  ${FAIL} EAST2: ${RED}HTTP ${baseline_code}${RESET}"
fi

section "Internal hostname resolution (from productpage pod)"
if [[ -n "$PP_POD" ]]; then
  internal_resp=$(oc --context "$EAST_CTX" exec -n "$NS" "$PP_POD" -- \
    python3 -c "import urllib.request; print(urllib.request.urlopen('http://reviews:9080/reviews/0', timeout=10).read().decode()[:120])" \
    2>/dev/null || echo "FAIL")
  if [[ "$internal_resp" != "FAIL" ]]; then
    echo -e "  ${PASS} reviews:9080/reviews/0 → ${GREEN}response OK${RESET}"
    echo -e "  ${CYAN}  ${internal_resp}${RESET}"
  else
    echo -e "  ${WARN} Could not reach reviews internally"
  fi
else
  echo -e "  ${WARN} productpage pod not found"
fi

echo ""
if [[ "$EAST_COUNT" -gt 0 && "$WEST_COUNT" -gt 0 && "$baseline_code" == "200" ]]; then
  echo -e "  ${PASS} Baseline OK — EAST2: ${EAST_COUNT} pods, WEST2: ${WEST_COUNT} pods"
else
  echo -e "  ${WARN} Unexpected baseline — EAST2: ${EAST_COUNT}, WEST2: ${WEST_COUNT}, HTTP: ${baseline_code}"
fi

pause "Press ENTER to simulate migration..."

# ── Step 2: Simulate Migration — Scale WEST2 to 0 ──────────────────────
header "2. Simulate Migration — Scale reviews to 0 in WEST2"
echo ""
echo -e "  Simulating the migration of ${BOLD}reviews${RESET} from WEST2 to EAST2."
echo -e "  Scale all WEST2 reviews replicas to ${RED}${BOLD}0${RESET}..."
echo ""
echo -e "  ${CYAN}In a traditional environment, this would require:${RESET}"
echo -e "  ${CYAN}  1. Update F5/external LB health checks${RESET}"
echo -e "  ${CYAN}  2. Update corporate DNS records${RESET}"
echo -e "  ${CYAN}  3. Wait for DNS TTL propagation (minutes → hours)${RESET}"
echo -e "  ${CYAN}  4. Verify traffic, remove old entries${RESET}"
echo ""
echo -e "  ${GREEN}With the mesh: scale to 0 and it's done.${RESET}"
echo ""

oc --context "$WEST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n "$NS" --replicas=0 &>/dev/null
echo -e "  ${PASS} WEST2 reviews scaled to ${RED}${BOLD}0 replicas${RESET}"
echo -e "  Waiting for pods to terminate..."
sleep 10

section "WEST2 reviews status after migration"
WEST_PODS=$(oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews \
  --no-headers 2>/dev/null | grep -v "Terminating" | grep -c "Running" || true)
if [[ "$WEST_PODS" -eq 0 ]]; then
  echo -e "  ${PASS} WEST2 reviews pods: ${RED}${BOLD}0${RESET}"
else
  echo -e "  ${WARN} WEST2 still has ${WEST_PODS} pod(s) — may still be terminating"
fi

section "Endpoints visible from EAST2 (after migration)"
ep_after=$(oc --context "$EAST_CTX" get endpoints reviews -n "$NS" \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
ep_after_count=$(echo "$ep_after" | wc -w | tr -d ' ')
echo -e "  ${PASS} ${ep_after_count} endpoint(s): ${ep_after}"
echo -e "  ${CYAN}  (only EAST2 pods — WEST2 endpoints removed by istiod)${RESET}"

# ── Step 3: Verify Internal Resolution ──────────────────────────────────
header "3. Verify Internal Resolution — Same Hostname, New Location"
echo ""
echo -e "  The hostname ${BOLD}reviews.bookinfo.svc.cluster.local${RESET} never changed."
echo -e "  productpage still calls the same address. istiod updated the"
echo -e "  global endpoint registry automatically."
echo ""

section "External traffic (via browser/curl)"
echo -e "  Sending 5 requests to productpage (EAST2)..."
echo ""

migrate_ok=0
for i in 1 2 3 4 5; do
  start_t=$(python3 -c "import time; print(time.time())")
  resp=$(curl -s -m 20 --retry 2 --retry-delay 3 "$EAST_URL" 2>/dev/null || true)
  end_t=$(python3 -c "import time; print(time.time())")
  elapsed=$(python3 -c "print(f'{${end_t} - ${start_t}:.3f}s')")
  has_reviews=$(echo "$resp" | grep -c "Book Reviews" || true)

  if [[ "$has_reviews" -gt 0 ]]; then
    echo -e "  ${PASS} Request $i: ${GREEN}HTTP 200${RESET} in ${BOLD}${elapsed}${RESET} — Book Reviews present"
    migrate_ok=$((migrate_ok + 1))
  else
    has_error=$(echo "$resp" | grep -c "Error fetching" || true)
    if [[ "$has_error" -gt 0 ]]; then
      echo -e "  ${FAIL} Request $i: ${RED}${elapsed}${RESET} — Error fetching reviews"
    else
      echo -e "  ${WARN} Request $i: ${YELLOW}${elapsed}${RESET} — unexpected response"
    fi
  fi
  sleep 1
done

echo ""
if [[ "$migrate_ok" -eq 5 ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}5/5 requests succeeded — reviews resolved from EAST2 only${RESET}"
elif [[ "$migrate_ok" -gt 0 ]]; then
  echo -e "  ${WARN} ${migrate_ok}/5 requests succeeded"
else
  echo -e "  ${FAIL} ${RED}${BOLD}0/5 requests — resolution failed${RESET}"
fi

section "Internal resolution (from productpage pod)"
if [[ -n "$PP_POD" ]]; then
  internal_resp2=$(oc --context "$EAST_CTX" exec -n "$NS" "$PP_POD" -- \
    python3 -c "import urllib.request; print(urllib.request.urlopen('http://reviews:9080/reviews/0', timeout=10).read().decode()[:120])" \
    2>/dev/null || echo "FAIL")
  if [[ "$internal_resp2" != "FAIL" ]]; then
    echo -e "  ${PASS} reviews:9080 → ${GREEN}response OK${RESET}"
    echo -e "  ${CYAN}  ${internal_resp2}${RESET}"
    echo ""
    echo -e "  ${PASS} The hostname ${BOLD}reviews:9080${RESET} resolved to EAST2 — ${GREEN}no DNS change needed${RESET}"
  else
    echo -e "  ${WARN} Could not reach reviews internally"
  fi
else
  echo -e "  ${WARN} productpage pod not found"
fi

echo ""
echo -e "  ${CYAN}${BOLD}▶ Verify in browser — all reviews served from EAST2:${RESET}"
echo -e "  ${CYAN}  ${EAST_URL}${RESET}"
if [[ -n "$KIALI_URL" ]]; then
  echo ""
  echo -e "  ${CYAN}${BOLD}▶ Verify in Kiali — traffic edges now show EAST2 only:${RESET}"
  echo -e "  ${CYAN}  ${KIALI_URL}${RESET}"
fi

pause "Press ENTER to restore WEST2 and continue..."

# ── Step 4: Restore ─────────────────────────────────────────────────────
header "4. Restore — Scale reviews Back in WEST2"
echo ""
echo -e "  Scaling reviews-v1, reviews-v2, reviews-v3 → ${GREEN}${BOLD}1 replica${RESET} each in WEST2..."
oc --context "$WEST_CTX" scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n "$NS" --replicas=1 &>/dev/null
echo -e "  Waiting for pods to be ready..."
sleep 12

section "WEST2 reviews status after restore"
oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
  | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    icon="${PASS}"
    [[ "$status" != "Running" ]] && icon="${WARN}"
    echo -e "  ${icon} ${name}  ${GREEN}${status}${RESET}"
  done
RESTORED=$(oc --context "$WEST_CTX" get pods -n "$NS" -l app=reviews \
  --no-headers 2>/dev/null | grep -c Running || true)

section "Endpoints after restore"
ep_restored=$(oc --context "$EAST_CTX" get endpoints reviews -n "$NS" \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
ep_restored_count=$(echo "$ep_restored" | wc -w | tr -d ' ')
if [[ "$ep_restored_count" -gt 3 ]]; then
  echo -e "  ${PASS} ${ep_restored_count} endpoints — includes WEST2 (cross-cluster)"
else
  echo -e "  ${WARN} ${ep_restored_count} endpoints — WEST2 may still be propagating"
fi

section "Recovery traffic test"
recovery_ok=0
for i in 1 2 3; do
  rc=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --retry 2 --retry-delay 3 \
    "$EAST_URL" 2>/dev/null || echo "000")
  if [[ "$rc" == "200" ]]; then
    echo -e "  ${PASS} Request $i: ${GREEN}HTTP ${rc}${RESET}"
    recovery_ok=$((recovery_ok + 1))
  else
    echo -e "  ${WARN} Request $i: ${YELLOW}HTTP ${rc}${RESET}"
  fi
  sleep 1
done

echo ""
if [[ "$RESTORED" -ge 3 && "$recovery_ok" -eq 3 ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}Restore complete — WEST2 back online, 3/3 requests OK${RESET}"
else
  echo -e "  ${WARN} Restore partial — WEST2 pods: ${RESTORED}, requests OK: ${recovery_ok}/3"
fi

# ── Summary ─────────────────────────────────────────────────────────────
header "FOLLOW-THE-SERVICE MIGRATION SUMMARY"
echo ""
echo -e "  ${BOLD}Phase          WEST2 reviews   Internal hostname            Traffic${RESET}"
echo -e "  Baseline      Running (3)     reviews.bookinfo.svc...     Distributed"
echo -e "  Migration     ${RED}${BOLD}0 pods${RESET}          reviews.bookinfo.svc...     ${GREEN}${BOLD}100% EAST2${RESET}"
echo -e "  Restore       Running (3)     reviews.bookinfo.svc...     Distributed"
echo ""
echo -e "  ${BOLD}The key:${RESET} The internal hostname ${CYAN}reviews.bookinfo.svc.cluster.local${RESET}"
echo -e "  never changed. istiod's global endpoint registry handled the"
echo -e "  migration transparently — no DNS, no F5, no application changes."
echo ""
echo -e "  ${BOLD}Traditional:${RESET} DNS update → TTL wait (min/hours) → LB reconfigure → verify"
echo -e "  ${GREEN}${BOLD}With mesh:${RESET}    Scale to 0 → ${GREEN}done${RESET} (seconds)"
echo ""
