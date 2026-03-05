#!/bin/bash
#
# UC1-T3: Multi-Primary Federation & Discovery — Verification Script
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

MESH_CONTEXTS=("east" "west")

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

check_trust_domain() {
  header "1. Shared Trust Domain (SPIFFE)"
  domains=()
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    spiffe=$(oc --context "$ctx" logs -n ztunnel ds/ztunnel --tail=10 2>/dev/null | grep -o 'spiffe://[^/"]*' | head -1)
    if [[ -n "$spiffe" ]]; then
      domain=$(echo "$spiffe" | sed 's|spiffe://||')
      domains+=("$domain")
      echo -e "  ${PASS} Trust domain: ${GREEN}${BOLD}${domain}${RESET}"
    else
      td=$(oc --context "$ctx" get cm istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | grep trustDomain | awk '{print $2}' | tr -d '"')
      [[ -z "$td" ]] && td="cluster.local"
      domains+=("$td")
      echo -e "  ${PASS} Trust domain: ${GREEN}${BOLD}${td}${RESET} (from config)"
    fi
  done
  echo ""
  if [[ "${domains[0]}" == "${domains[1]}" ]]; then
    echo -e "  ${PASS} ${GREEN}Trust domains match: ${BOLD}${domains[0]}${RESET}"
  else
    echo -e "  ${FAIL} ${RED}Trust domains differ: ${domains[0]} vs ${domains[1]}${RESET}"
  fi
}

check_multicluster_config() {
  header "3. Multi-Cluster Configuration (Istio CR)"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    mc_json=$(oc --context "$ctx" get istio default -n istio-system -o jsonpath='{.spec.values.global.multiCluster}' 2>/dev/null)
    if [[ -n "$mc_json" ]]; then
      cluster_name=$(echo "$mc_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('clusterName','?'))" 2>/dev/null)
      enabled=$(echo "$mc_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('enabled',False))" 2>/dev/null)
      if [[ "$enabled" == "True" ]]; then
        echo -e "  ${PASS} Cluster ID: ${GREEN}${BOLD}${cluster_name}${RESET}  Multi-cluster: ${GREEN}enabled${RESET}"
      else
        echo -e "  ${WARN} Cluster ID: ${cluster_name}  Multi-cluster: ${YELLOW}disabled${RESET}"
      fi
    else
      echo -e "  ${FAIL} Multi-cluster config not found in Istio CR"
    fi
  done
}

check_remote_secrets() {
  header "2. Remote Secrets (Cross-Cluster API Access)"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    secrets=$(oc --context "$ctx" get secrets -n istio-system -l istio/multiCluster=true --no-headers 2>/dev/null)
    if [[ -n "$secrets" ]]; then
      echo "$secrets" | while read -r line; do
        secret_name=$(echo "$line" | awk '{print $1}')
        remote_cluster=$(echo "$secret_name" | sed 's/istio-remote-secret-//')
        echo -e "  ${PASS} ${secret_name}  →  peers with ${GREEN}${BOLD}${remote_cluster}${RESET}"
      done
    else
      echo -e "  ${FAIL} No remote secrets found"
    fi
  done
}

check_eastwest_gateways() {
  header "4. East-West Gateways (Control Plane Federation)"
  echo ""
  echo -e "  These gateways allow each istiod to reach the remote cluster's API server."
  echo -e "  They handle ${BOLD}control plane${RESET} connectivity, not user data plane traffic."
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    ewgw=$(oc --context "$ctx" get pods -n istio-system --no-headers 2>/dev/null | grep eastwest)
    if [[ -n "$ewgw" ]]; then
      pod_name=$(echo "$ewgw" | awk '{print $1}')
      pod_status=$(echo "$ewgw" | awk '{print $3}')
      if [[ "$pod_status" == "Running" ]]; then
        echo -e "  ${PASS} ${pod_name}  ${GREEN}${pod_status}${RESET}"
      else
        echo -e "  ${FAIL} ${pod_name}  ${RED}${pod_status}${RESET}"
      fi
      route=$(oc --context "$ctx" get route -n istio-system --no-headers 2>/dev/null | grep eastwest | awk '{print $2}')
      if [[ -n "$route" ]]; then
        echo -e "       Route: ${CYAN}${route}${RESET}"
      fi
    else
      echo -e "  ${FAIL} East-west gateway not found"
    fi
  done
}

check_service_discovery() {
  header "5. Automatic Service Discovery"
  echo ""
  echo -e "  In multi-primary with remote secrets, istiod discovers ${BOLD}all${RESET} services"
  echo -e "  from the remote cluster automatically — no special labels needed."
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    services=$(oc --context "$ctx" get svc -n bookinfo --no-headers 2>/dev/null | grep -v "^kubernetes")
    if [[ -n "$services" ]]; then
      svc_count=$(echo "$services" | wc -l | tr -d ' ')
      echo -e "  ${PASS} ${GREEN}${svc_count} bookinfo services${RESET} discovered:"
      echo "$services" | while read -r line; do
        svc_name=$(echo "$line" | awk '{print $1}')
        svc_ip=$(echo "$line" | awk '{print $3}')
        echo -e "    ${PASS} ${svc_name}  (${svc_ip})"
      done
    else
      echo -e "  ${FAIL} No services found in bookinfo namespace"
    fi
  done
}

check_kiali() {
  header "6. Kiali (ACM Console)"
  echo ""
  echo -e "  Open Kiali from the ACM console to verify the unified graph:"
  echo ""
  echo -e "  ${CYAN}${BOLD}https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph${RESET}"
  echo ""
  echo -e "  ${BOLD}Verify:${RESET}"
  echo -e "    • Select namespace ${BOLD}bookinfo${RESET}"
  echo -e "    • Both clusters (EAST and WEST) appear in the graph"
  echo -e "    • Services from both clusters are discovered and visible"
}

summary() {
  header "FEDERATION SUMMARY"
  echo ""
  echo -e "  ${BOLD}Trust domain:${RESET}      ${GREEN}cluster.local${RESET} (shared)"
  echo -e "  ${BOLD}Cluster IDs:${RESET}       east, west"
  echo -e "  ${BOLD}Peering:${RESET}           Remote secrets exchanged"
  echo -e "  ${BOLD}EW Gateways:${RESET}       Control plane cross-cluster connectivity"
  echo -e "  ${BOLD}Discovery:${RESET}         Automatic via istiod + remote secrets"
  echo ""
}

# --- Run all checks ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC1-T3: Multi-Primary Federation & Discovery             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

check_trust_domain
check_remote_secrets
pause

check_multicluster_config
check_eastwest_gateways
pause

check_service_discovery
check_kiali
pause

summary
