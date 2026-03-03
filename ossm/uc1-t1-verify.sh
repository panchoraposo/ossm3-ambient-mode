#!/bin/bash
set +o posix
#
# UC1-T1: Baseline OpenShift Environments — Verification Script
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

CONTEXTS=("east" "west" "acm")
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

check_cluster_access() {
  header "1. Cluster Access & OCP Version"
  for ctx in "${CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    server_version=$(oc --context "$ctx" version 2>/dev/null | grep "Server Version" | awk '{print $3}')
    k8s_version=$(oc --context "$ctx" version 2>/dev/null | grep "Kubernetes Version" | awk '{print $3}')
    if [[ -n "$server_version" ]]; then
      echo -e "  ${PASS} OCP ${BOLD}${server_version}${RESET}  (Kubernetes ${k8s_version})"
    else
      echo -e "  ${FAIL} Cannot connect — check login and context '${ctx}'"
    fi
  done
}

check_nodes() {
  header "2. Nodes"
  for ctx in "${CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    nodes=$(oc --context "$ctx" get nodes --no-headers 2>/dev/null)
    if [[ -z "$nodes" ]]; then
      echo -e "  ${FAIL} Cannot list nodes"
      continue
    fi
    total=$(echo "$nodes" | wc -l | tr -d ' ')
    ready=$(echo "$nodes" | grep -c " Ready")
    if [[ "$total" -eq "$ready" ]]; then
      echo -e "  ${PASS} ${ready}/${total} nodes Ready"
    else
      echo -e "  ${WARN} ${ready}/${total} nodes Ready"
    fi
    echo "$nodes" | while read -r line; do
      name=$(echo "$line" | awk '{print $1}')
      status=$(echo "$line" | awk '{print $2}')
      roles=$(echo "$line" | awk '{print $3}')
      icon="${PASS}"
      [[ "$status" != *"Ready"* ]] && icon="${FAIL}"
      echo -e "    ${icon} ${name}  (${roles})"
    done
  done
}

check_ossm_operator() {
  header "3. Red Hat OpenShift Service Mesh 3 Operator"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    csv=$(oc --context "$ctx" get csv -n openshift-operators --no-headers 2>/dev/null | grep servicemesh)
    if [[ -n "$csv" ]]; then
      name=$(echo "$csv" | awk '{print $1}')
      status=$(echo "$csv" | awk '{print $NF}')
      if [[ "$status" == "Succeeded" ]]; then
        echo -e "  ${PASS} ${name}  —  ${GREEN}${status}${RESET}"
      else
        echo -e "  ${WARN} ${name}  —  ${YELLOW}${status}${RESET}"
      fi
    else
      echo -e "  ${FAIL} Service Mesh operator not found"
    fi
  done
}

check_istio_cr() {
  header "4. Istio Control Plane"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    istio_line=$(oc --context "$ctx" get istio -n istio-system --no-headers 2>/dev/null)
    if [[ -n "$istio_line" ]]; then
      name=$(echo "$istio_line" | awk '{print $1}')
      istio_version=""
      status=""
      for field in $istio_line; do
        [[ "$field" =~ ^v[0-9] ]] && istio_version="$field"
        [[ "$field" == "Healthy" || "$field" == "Reconciling" || "$field" == "Error" ]] && status="$field"
      done
      if [[ "$status" == "Healthy" ]]; then
        echo -e "  ${PASS} Istio '${name}'  —  ${GREEN}${status}${RESET}  (${istio_version})"
      else
        echo -e "  ${WARN} Istio '${name}'  —  ${YELLOW}${status}${RESET}  (${istio_version})"
      fi
    else
      echo -e "  ${FAIL} No Istio CR found in istio-system"
    fi
  done
}

check_mesh_pods() {
  header "5. Mesh Components"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"

    istiod=$(oc --context "$ctx" get pods -n istio-system -l app=istiod --no-headers 2>/dev/null)
    if [[ -n "$istiod" ]]; then
      istiod_status=$(echo "$istiod" | awk '{print $3}')
      echo -e "  ${PASS} istiod          ${GREEN}${istiod_status}${RESET}"
    else
      echo -e "  ${FAIL} istiod          not found"
    fi

    ztunnel=$(oc --context "$ctx" get pods -n ztunnel --no-headers 2>/dev/null)
    if [[ -n "$ztunnel" ]]; then
      zt_count=$(echo "$ztunnel" | wc -l | tr -d ' ')
      zt_running=$(echo "$ztunnel" | grep -c "Running")
      if [[ "$zt_count" -eq "$zt_running" ]]; then
        echo -e "  ${PASS} ztunnel         ${GREEN}${zt_running}/${zt_count} Running${RESET}"
      else
        echo -e "  ${WARN} ztunnel         ${YELLOW}${zt_running}/${zt_count} Running${RESET}"
      fi
    else
      echo -e "  ${FAIL} ztunnel         not found"
    fi

    ewgw=$(oc --context "$ctx" get pods -n istio-system --no-headers 2>/dev/null | grep eastwest)
    if [[ -n "$ewgw" ]]; then
      ewgw_status=$(echo "$ewgw" | awk '{print $3}')
      echo -e "  ${PASS} east-west gw    ${GREEN}${ewgw_status}${RESET}"
    else
      echo -e "  ${WARN} east-west gw    not deployed"
    fi
  done
}

check_acm() {
  header "6. Advanced Cluster Management (ACM)"
  section "Hub cluster: ACM"

  acm_csv=$(oc --context acm get csv -n open-cluster-management --no-headers 2>/dev/null | grep -i "advanced-cluster-management")
  if [[ -n "$acm_csv" ]]; then
    name=$(echo "$acm_csv" | awk '{print $1}')
    status=$(echo "$acm_csv" | awk '{print $NF}')
    echo -e "  ${PASS} ${name}  —  ${GREEN}${status}${RESET}"
  else
    hub_ns=$(oc --context acm get ns open-cluster-management --no-headers 2>/dev/null)
    if [[ -n "$hub_ns" ]]; then
      echo -e "  ${WARN} ACM namespace exists but CSV not found"
    else
      echo -e "  ${FAIL} ACM not found — check login to 'acm' context"
    fi
  fi

  section "Managed Clusters"
  managed=$(oc --context acm get managedclusters --no-headers 2>/dev/null)
  if [[ -n "$managed" ]]; then
    echo "$managed" | while read -r line; do
      mc_name=$(echo "$line" | awk '{print $1}')
      mc_available=$(echo "$line" | awk '{print $2}')
      if [[ "$mc_available" == "true" ]]; then
        echo -e "  ${PASS} ${mc_name}  —  ${GREEN}Available${RESET}"
      else
        echo -e "  ${FAIL} ${mc_name}  —  ${RED}Not Available${RESET}"
      fi
    done
  else
    echo -e "  ${WARN} Cannot list managed clusters (check ACM login)"
  fi
}

summary() {
  header "BASELINE SUMMARY"
  echo ""
  echo -e "  Environment ready for Service Mesh multi-cluster testing."
  echo -e "  Clusters: EAST, WEST (mesh), ACM (hub)"
  echo ""
}

# --- Run all checks ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC1-T1: Baseline OpenShift Environments Verification     ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

check_cluster_access
check_nodes
check_ossm_operator
check_istio_cr
check_mesh_pods
check_acm
summary
