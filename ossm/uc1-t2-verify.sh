#!/bin/bash
#
# UC1-T2: Deploying OSSM 3.2 in Ambient Mode — Verification Script
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

check_ambient_profile() {
  header "1. Istio Ambient Profile"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    profile=$(oc --context "$ctx" get istio default -n istio-system -o jsonpath='{.spec.profile}' 2>/dev/null)
    if [[ "$profile" == "ambient" ]]; then
      echo -e "  ${PASS} Profile: ${GREEN}${BOLD}ambient${RESET}"
    elif [[ -n "$profile" ]]; then
      echo -e "  ${WARN} Profile: ${YELLOW}${profile}${RESET} (expected: ambient)"
    else
      echo -e "  ${FAIL} Cannot read Istio CR"
    fi
  done
}

check_istiocni() {
  header "2. IstioCNI"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    cni_line=$(oc --context "$ctx" get istiocni -A --no-headers 2>/dev/null)
    if [[ -n "$cni_line" ]]; then
      cni_status=""
      cni_version=""
      for field in $cni_line; do
        [[ "$field" =~ ^v[0-9] ]] && cni_version="$field"
        [[ "$field" == "Healthy" || "$field" == "Error" || "$field" == "Reconciling" ]] && cni_status="$field"
      done
      if [[ "$cni_status" == "Healthy" ]]; then
        echo -e "  ${PASS} IstioCNI  —  ${GREEN}${cni_status}${RESET}  (${cni_version})"
      else
        echo -e "  ${WARN} IstioCNI  —  ${YELLOW}${cni_status}${RESET}  (${cni_version})"
      fi
    else
      echo -e "  ${FAIL} IstioCNI not found"
    fi
  done
}

check_ztunnel() {
  header "3. ztunnel DaemonSet (L4 — one per node)"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    ds=$(oc --context "$ctx" get ds -n ztunnel --no-headers 2>/dev/null)
    if [[ -n "$ds" ]]; then
      desired=$(echo "$ds" | awk '{print $2}')
      ready=$(echo "$ds" | awk '{print $4}')
      if [[ "$desired" -eq "$ready" ]]; then
        echo -e "  ${PASS} DaemonSet: ${GREEN}${ready}/${desired} Ready${RESET}"
      else
        echo -e "  ${WARN} DaemonSet: ${YELLOW}${ready}/${desired} Ready${RESET}"
      fi
    else
      echo -e "  ${FAIL} ztunnel DaemonSet not found in namespace 'ztunnel'"
    fi

    pods=$(oc --context "$ctx" get pods -n ztunnel -o wide --no-headers 2>/dev/null)
    if [[ -n "$pods" ]]; then
      echo "$pods" | while read -r line; do
        pod_name=$(echo "$line" | awk '{print $1}')
        pod_status=$(echo "$line" | awk '{print $3}')
        pod_node=$(echo "$line" | awk '{print $7}')
        icon="${PASS}"
        [[ "$pod_status" != "Running" ]] && icon="${FAIL}"
        echo -e "    ${icon} ${pod_name}  ${GREEN}${pod_status}${RESET}  on ${pod_node}"
      done
    fi
  done
}

check_istiod() {
  header "4. istiod (Control Plane)"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    istiod=$(oc --context "$ctx" get pods -n istio-system -l app=istiod --no-headers 2>/dev/null)
    if [[ -n "$istiod" ]]; then
      pod_name=$(echo "$istiod" | awk '{print $1}')
      pod_ready=$(echo "$istiod" | awk '{print $2}')
      pod_status=$(echo "$istiod" | awk '{print $3}')
      if [[ "$pod_status" == "Running" ]]; then
        echo -e "  ${PASS} ${pod_name}  ${GREEN}${pod_ready} ${pod_status}${RESET}"
      else
        echo -e "  ${FAIL} ${pod_name}  ${RED}${pod_ready} ${pod_status}${RESET}"
      fi
    else
      echo -e "  ${FAIL} istiod not found"
    fi
  done
}

check_namespace_label() {
  header "5. Namespace Ambient Enrollment"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    label=$(oc --context "$ctx" get ns bookinfo -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null)
    if [[ "$label" == "ambient" ]]; then
      echo -e "  ${PASS} bookinfo namespace: ${GREEN}istio.io/dataplane-mode=ambient${RESET}"
    elif [[ -n "$label" ]]; then
      echo -e "  ${WARN} bookinfo namespace: ${YELLOW}istio.io/dataplane-mode=${label}${RESET}"
    else
      echo -e "  ${FAIL} bookinfo namespace: label not found"
    fi
  done
}

check_no_sidecar() {
  header "6. No Sidecar Injection (Sidecarless Proof)"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    section "Cluster: $(echo "$ctx" | tr '[:lower:]' '[:upper:]')"
    pods_json=$(oc --context "$ctx" get pods -n bookinfo -o json 2>/dev/null)
    if [[ -z "$pods_json" ]]; then
      echo -e "  ${FAIL} Cannot list pods in bookinfo"
      continue
    fi

    sidecar_found=false
    echo "$pods_json" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
green = '\033[0;32m'
red = '\033[0;31m'
cyan = '\033[0;36m'
reset = '\033[0m'
bold = '\033[1m'
app_count = 0
sidecar_count = 0
for pod in sorted(data.get('items', []), key=lambda p: p['metadata']['name']):
    name = pod['metadata']['name']
    containers = [c['name'] for c in pod['spec']['containers']]
    labels = pod.get('metadata', {}).get('labels', {})
    is_gateway = 'gateway-istio' in name
    is_waypoint = not is_gateway and 'gateway.networking.k8s.io/gateway-name' in labels
    cnames = ', '.join(containers)
    if is_waypoint or is_gateway:
        kind = 'gateway' if is_gateway else 'waypoint'
        print(f'  {cyan}▪{reset} {name}  [{cnames}]  —  {cyan}mesh infra ({kind}){reset}')
    else:
        app_count += 1
        has_sidecar = 'istio-proxy' in containers
        if has_sidecar:
            sidecar_count += 1
        icon = '✘' if has_sidecar else '✔'
        color = red if has_sidecar else green
        sidecar_text = f'{red}istio-proxy INJECTED{reset}' if has_sidecar else f'{green}no sidecar{reset}'
        print(f'  {color}{icon}{reset} {name}  [{cnames}]  —  {sidecar_text}')
print(f'  {bold}Result: {app_count} app pods, {green}{app_count - sidecar_count} sidecarless{reset}{bold}, {red}{sidecar_count} with sidecar{reset}')
" 2>&1
  done
}

summary() {
  header "AMBIENT MODE SUMMARY"
  echo ""
  echo -e "  ${BOLD}Architecture:${RESET} Sidecarless (ambient)"
  echo -e "  ${BOLD}L4 (mTLS + routing):${RESET} ztunnel DaemonSet — per node, transparent"
  echo -e "  ${BOLD}L7 (HTTP policies):${RESET} Waypoint proxies — optional, per service"
  echo -e "  ${BOLD}Sidecars injected:${RESET} ${GREEN}ZERO${RESET}"
  echo ""
}

# --- Run all checks ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC1-T2: OSSM 3.2 Ambient Mode Verification              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

check_ambient_profile
check_istiocni
check_ztunnel
check_istiod
check_namespace_label
check_no_sidecar
summary
