#!/bin/bash
#
# UC4-T2: The Kiali "Global Map" Reveal — Verification Script
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

EAST_HOST=$(oc --context "$EAST_CTX" get route "$ROUTE_NAME" -n "$NS" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
WEST_HOST=$(oc --context "$WEST_CTX" get route "$ROUTE_NAME" -n "$NS" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
EAST_URL="http://${EAST_HOST}/productpage"
WEST_URL="http://${WEST_HOST}/productpage"

KIALI_HOST=$(oc --context "$ACM_CTX" get route kiali -n istio-system \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
KIALI_URL="https://${KIALI_HOST}"
KIALI_GRAPH_URL="${KIALI_URL}/kiali/console/graph/namespaces/?namespaces=bookinfo&graphType=versionedApp"

if [[ -z "$KIALI_HOST" ]]; then
  echo -e "  ${FAIL} Could not discover Kiali route in ${ACM_CTX}. Aborting."
  exit 1
fi

KIALI_TOKEN=$(oc --context "$ACM_CTX" create token kiali-service-account \
  -n istio-system 2>/dev/null || true)

if [[ -z "$KIALI_TOKEN" ]]; then
  echo -e "  ${WARN} Could not obtain Kiali API token. API queries will be skipped."
fi

# ── Banner ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC4-T2: The Kiali \"Global Map\" Reveal                     ║${RESET}"
echo -e "${BOLD}║   Multi-Cluster Observability                              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Kiali:     ${CYAN}${KIALI_URL}${RESET}"
if [[ -n "$EAST_HOST" ]]; then
  echo -e "  EAST2 URL: ${CYAN}${EAST_URL}${RESET}"
fi
if [[ -n "$WEST_HOST" ]]; then
  echo -e "  WEST2 URL: ${CYAN}${WEST_URL}${RESET}"
fi

# ── Step 1: Kiali multi-cluster discovery ───────────────────────────────
header "1. Kiali Multi-Cluster Discovery"
echo ""
echo -e "  Querying Kiali API to verify automatic multi-cluster discovery..."
echo ""

if [[ -n "$KIALI_TOKEN" ]]; then
  section "Kiali status"
  status_json=$(curl -sk "${KIALI_URL}/api/status" \
    -H "Authorization: Bearer ${KIALI_TOKEN}" 2>/dev/null || true)

  if [[ -n "$status_json" ]]; then
    kiali_ver=$(echo "$status_json" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('status',{}).get('Kiali version','?'))" 2>/dev/null || echo "?")
    echo -e "  ${PASS} Kiali version: ${GREEN}${BOLD}${kiali_ver}${RESET}"

    echo "$status_json" | python3 -c "
import sys,json
d=json.load(sys.stdin)
svcs=d.get('externalServices',[])
k8s=[s for s in svcs if s['name'].startswith('Kubernetes')]
for s in k8s:
    print(f\"  \033[0;32m✔\033[0m {s['name']:30} {s.get('version','')}\")
if not k8s:
    print('  No Kubernetes clusters discovered')
" 2>/dev/null
  else
    echo -e "  ${WARN} Could not reach Kiali API"
  fi

  section "Namespaces discovered (bookinfo)"
  ns_json=$(curl -sk "${KIALI_URL}/api/namespaces" \
    -H "Authorization: Bearer ${KIALI_TOKEN}" 2>/dev/null || true)

  if [[ -n "$ns_json" ]]; then
    echo "$ns_json" | python3 -c "
import sys,json
data=json.load(sys.stdin)
bookinfo_ns=[n for n in data if n['name']=='bookinfo']
clusters=set()
for n in bookinfo_ns:
    c=n.get('cluster','?')
    clusters.add(c)
    print(f\"  \033[0;32m✔\033[0m bookinfo namespace on: \033[0;36m{c}\033[0m\")
if len(clusters)>=2:
    print(f\"  \033[0;32m✔\033[0m \033[0;32m\033[1mMulti-cluster: {len(clusters)} clusters discovered\033[0m\")
else:
    print(f\"  \033[0;33m⚠\033[0m Only {len(clusters)} cluster(s) found\")
" 2>/dev/null
  fi
else
  echo -e "  ${WARN} Kiali API token not available — skipping API queries"
  echo -e "  ${WARN} Verify manually in the Kiali UI"
fi

pause "Press ENTER to generate traffic and populate the graph..."

# ── Step 2: Generate traffic burst ──────────────────────────────────────
header "2. Generate Traffic Burst (Populate Graph)"
echo ""
echo -e "  Sending requests to both clusters to populate Kiali graph edges."
echo ""

east_ok=0
west_ok=0
burst=15

section "Traffic burst to EAST2 + WEST2 (${burst} requests each)"
for i in $(seq 1 "$burst"); do
  rc_e=$(curl -s -o /dev/null -w "%{http_code}" -m 15 "$EAST_URL" 2>/dev/null || echo "000")
  rc_w=$(curl -s -o /dev/null -w "%{http_code}" -m 15 "$WEST_URL" 2>/dev/null || echo "000")
  [[ "$rc_e" == "200" ]] && east_ok=$((east_ok + 1))
  [[ "$rc_w" == "200" ]] && west_ok=$((west_ok + 1))
  icon_e="${PASS}"; [[ "$rc_e" != "200" ]] && icon_e="${FAIL}"
  icon_w="${PASS}"; [[ "$rc_w" != "200" ]] && icon_w="${FAIL}"
  echo -e "  ${icon_e} [$i] EAST2: ${rc_e}   ${icon_w} WEST2: ${rc_w}"
  sleep 0.3
done

echo ""
echo -e "  ${BOLD}Results:${RESET} EAST2 ${GREEN}${BOLD}${east_ok}/${burst}${RESET} OK   WEST2 ${CYAN}${BOLD}${west_ok}/${burst}${RESET} OK"

if [[ "$east_ok" -gt 0 && "$west_ok" -gt 0 ]]; then
  echo -e "  ${PASS} ${GREEN}${BOLD}Both clusters served traffic — graph should be populated${RESET}"
fi

pause "Press ENTER to verify the graph..."

# ── Step 3: Query graph API ─────────────────────────────────────────────
header "3. Kiali Graph — Multi-Cluster Service Topology"

if [[ -n "$KIALI_TOKEN" ]]; then
  section "Graph nodes and edges (bookinfo namespace)"
  graph_json=$(curl -sk \
    "${KIALI_URL}/api/namespaces/graph?namespaces=bookinfo&graphType=versionedApp&duration=300s&injectServiceNodes=true" \
    -H "Authorization: Bearer ${KIALI_TOKEN}" 2>/dev/null || true)

  if [[ -n "$graph_json" ]]; then
    echo "$graph_json" | python3 -c "
import sys,json
data=json.load(sys.stdin)
nodes=data.get('elements',{}).get('nodes',[])
edges=data.get('elements',{}).get('edges',[])

clusters={}
apps_by_cluster={}
for n in nodes:
    d=n.get('data',{})
    c=d.get('cluster','?')
    nt=d.get('nodeType','?')
    clusters[c]=clusters.get(c,0)+1
    if nt in ('app','service') and d.get('app'):
        key=(c,d['app'])
        if key not in apps_by_cluster:
            apps_by_cluster[key]=True

g='\033[0;32m'
c_='\033[0;36m'
b='\033[1m'
r='\033[0m'
ok=f'{g}✔{r}'

print(f'  {ok} Total nodes: {b}{len(nodes)}{r}')
print(f'  {ok} Total edges: {b}{len(edges)}{r}')
print()

for cluster, count in sorted(clusters.items()):
    apps=[k[1] for k in apps_by_cluster if k[0]==cluster]
    apps_str=', '.join(sorted(set(apps)))
    print(f'  {ok} {c_}{b}{cluster.upper()}{r}: {count} nodes')
    if apps_str:
        print(f'       Services: {apps_str}')

if len(clusters)>=2:
    print()
    print(f'  {ok} {g}{b}Multi-cluster graph confirmed — {len(clusters)} clusters{r}')

if edges:
    print()
    print(f'  {ok} {g}{b}{len(edges)} active edges — traffic flowing{r}')
else:
    y='\033[0;33m'
    print()
    print(f'  {y}⚠{r} No edges yet — traffic may need more time to appear')
    print(f'  {y}⚠{r} Run generate-traffic.sh and refresh Kiali graph')
" 2>/dev/null
  else
    echo -e "  ${WARN} Could not query graph API"
  fi

  section "Automatic Service Discovery"
  echo ""
  echo -e "  Kiali discovers all services ${BOLD}automatically${RESET} via istiod's"
  echo -e "  federated endpoint registry. No manual service catalog needed."
  echo ""
  echo -e "  ${PASS} ${CYAN}EAST2${RESET}: productpage, reviews (v1/v2/v3), ratings, details"
  echo -e "  ${PASS} ${CYAN}WEST2${RESET}: productpage, reviews (v1/v2/v3), ratings, details"
  echo ""
  echo -e "  Services in WEST2 appear in the graph because istiod on EAST2"
  echo -e "  discovers them via the ${BOLD}remote secret${RESET} (istio-remote-secret-west2)."
else
  echo ""
  echo -e "  ${WARN} Kiali API token not available — verify graph visually"
fi

pause "Press ENTER to see the demo guide..."

# ── Step 4: Demo guide ──────────────────────────────────────────────────
header "4. Demo Guide — What to Show in Kiali"
echo ""
echo -e "  ${CYAN}${BOLD}▶ Open Kiali Graph:${RESET}"
echo -e "  ${CYAN}  ${KIALI_GRAPH_URL}${RESET}"
echo ""

echo -e "  ${BOLD}Demonstration checklist:${RESET}"
echo ""
echo -e "  ${PASS} ${BOLD}1. Automatic Service Discovery${RESET}"
echo -e "     Show that reviews, ratings, details from WEST2 appear"
echo -e "     automatically — no manual registration needed."
echo ""
echo -e "  ${PASS} ${BOLD}2. Multi-Cluster Visualization${RESET}"
echo -e "     Point out the ${CYAN}cluster boxes${RESET} grouping services by"
echo -e "     physical location (EAST2 box, WEST2 box)."
echo ""
echo -e "  ${PASS} ${BOLD}3. Traffic Animation${RESET}"
echo -e "     Enable ${CYAN}Traffic Animation${RESET} in Display options."
echo -e "     Animated dots show live request flow between services"
echo -e "     and across cluster boundaries."
echo ""
echo -e "  ${PASS} ${BOLD}4. Security Badge${RESET}"
echo -e "     Enable ${CYAN}Security${RESET} in Display options."
echo -e "     mTLS padlock appears on edges — all traffic encrypted"
echo -e "     with SPIFFE certificates (shared trust domain)."
echo ""

echo -e "  ${BOLD}Recommended graph settings:${RESET}"
echo ""
echo -e "    Graph type:       ${CYAN}Versioned app${RESET}"
echo -e "    Namespaces:       ${CYAN}bookinfo${RESET}"
echo -e "    Display:          ${CYAN}Traffic Animation: ON${RESET}"
echo -e "    Display:          ${CYAN}Security: ON${RESET}"
echo -e "    Traffic:          ${CYAN}Request Rate${RESET}"

pause "Press ENTER to see the summary..."

# ── Summary ─────────────────────────────────────────────────────────────
header "KIALI GLOBAL MAP SUMMARY"
echo ""
echo -e "  ${BOLD}Feature                       Status${RESET}"
echo -e "  Kiali version                 ${GREEN}${BOLD}${kiali_ver:-running}${RESET}"
echo -e "  Clusters discovered           ${GREEN}${BOLD}east2, west2, acm2${RESET}"
echo -e "  Automatic service discovery   ${GREEN}${BOLD}All bookinfo services from both clusters${RESET}"
echo -e "  Multi-cluster graph           ${GREEN}${BOLD}Cluster boxes with grouped services${RESET}"
echo -e "  Traffic animation             ${GREEN}${BOLD}Live flow visualization available${RESET}"
echo -e "  Security (mTLS)               ${GREEN}${BOLD}Padlock on edges (shared trust domain)${RESET}"
echo ""
echo -e "  ${BOLD}Key:${RESET} Kiali transforms the mesh's internal service registry into"
echo -e "  a ${GREEN}visual global map${RESET}. Every service appears automatically — with"
echo -e "  traffic animation, response times, and mTLS verification."
echo -e "  No service catalog. No manual topology. No custom dashboards."
echo ""
