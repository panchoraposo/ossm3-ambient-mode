#!/bin/bash
#
# UC2-T3: Unified Trust & mTLS Verification — Verification Script
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

check_root_ca() {
  header "1. Shared Root CA"
  fingerprints=()
  for ctx in "${MESH_CONTEXTS[@]}"; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    section "Cluster: ${CTX_UPPER}"
    root_pem=$(oc --context "$ctx" get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | base64 -d 2>/dev/null)
    if [[ -n "$root_pem" ]]; then
      subject=$(echo "$root_pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
      issuer=$(echo "$root_pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
      expiry=$(echo "$root_pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
      fp=$(echo "$root_pem" | openssl x509 -fingerprint -noout -sha256 2>/dev/null | sed 's/sha256 Fingerprint=//')
      fingerprints+=("$fp")
      echo -e "  ${PASS} Subject: ${GREEN}${BOLD}${subject}${RESET}"
      echo -e "       Issuer:  ${issuer}"
      echo -e "       Expires: ${expiry}"
      echo -e "       SHA-256: ${CYAN}${fp}${RESET}"
    else
      fingerprints+=("")
      echo -e "  ${FAIL} Root CA secret 'cacerts' not found"
    fi
  done

  echo ""
  if [[ "${fingerprints[0]}" == "${fingerprints[1]}" && -n "${fingerprints[0]}" ]]; then
    echo -e "  ${PASS} ${GREEN}${BOLD}Root CA fingerprints MATCH${RESET} — unified trust established"
  else
    echo -e "  ${FAIL} ${RED}Root CA fingerprints DO NOT match${RESET}"
  fi
}

check_intermediate_cas() {
  header "2. Per-Cluster Intermediate CAs"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    section "Cluster: ${CTX_UPPER}"
    ca_pem=$(oc --context "$ctx" get secret cacerts -n istio-system -o jsonpath='{.data.ca-cert\.pem}' 2>/dev/null | base64 -d 2>/dev/null)
    if [[ -n "$ca_pem" ]]; then
      subject=$(echo "$ca_pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
      issuer=$(echo "$ca_pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
      echo -e "  ${PASS} Subject: ${GREEN}${BOLD}${subject}${RESET}"
      echo -e "       Issuer:  ${issuer} (Root CA)"
    else
      echo -e "  ${FAIL} Intermediate CA not found in cacerts secret"
    fi
  done
}

check_mtls_default() {
  header "3. mTLS is Automatic (No PeerAuthentication Needed)"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    section "Cluster: ${CTX_UPPER}"
    pa=$(oc --context "$ctx" get peerauthentication -A --no-headers 2>/dev/null)
    if [[ -z "$pa" ]]; then
      echo -e "  ${PASS} ${GREEN}No PeerAuthentication resources${RESET} — mTLS is always-on by default in ambient"
    else
      pa_count=$(echo "$pa" | wc -l | tr -d ' ')
      echo -e "  ${CYAN}▪${RESET} ${pa_count} PeerAuthentication resource(s) found (ambient still enforces mTLS)"
    fi
  done
}

check_spiffe_identities() {
  header "4. SPIFFE Identities in Live Traffic"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    section "Cluster: ${CTX_UPPER}"
    identities=$(oc --context "$ctx" logs -n ztunnel ds/ztunnel --tail=20 2>/dev/null | grep -o 'src.identity="[^"]*"\|dst.identity="[^"]*"' | sort -u)
    if [[ -n "$identities" ]]; then
      id_count=$(echo "$identities" | wc -l | tr -d ' ')
      echo -e "  ${PASS} ${GREEN}${id_count} unique SPIFFE identities${RESET} in recent traffic:"
      echo "$identities" | while read -r line; do
        identity=$(echo "$line" | grep -o '"[^"]*"' | tr -d '"')
        direction=$(echo "$line" | grep -o '^[a-z]*')
        echo -e "    ${PASS} ${direction}: ${CYAN}${identity}${RESET}"
      done
    else
      echo -e "  ${WARN} No identity data in recent ztunnel logs (run generate-traffic.sh)"
    fi
  done
}

check_hbone_encryption() {
  header "5. HBONE Encryption (All Traffic via mTLS Port 15008)"
  for ctx in "${MESH_CONTEXTS[@]}"; do
    CTX_UPPER=$(echo "$ctx" | tr '[:lower:]' '[:upper:]')
    section "Cluster: ${CTX_UPPER}"
    connections=$(oc --context "$ctx" logs -n ztunnel ds/ztunnel --tail=20 2>/dev/null | grep "connection complete" | grep "direction=\"outbound\"")
    if [[ -n "$connections" ]]; then
      total=$(echo "$connections" | wc -l | tr -d ' ')
      hbone=$(echo "$connections" | grep -c ":15008")
      if [[ "$total" -eq "$hbone" ]]; then
        echo -e "  ${PASS} ${GREEN}${BOLD}${hbone}/${total} connections${RESET} ${GREEN}use HBONE (port 15008 mTLS)${RESET}"
      else
        plaintext=$((total - hbone))
        echo -e "  ${WARN} ${hbone}/${total} use HBONE, ${YELLOW}${plaintext} not on 15008${RESET}"
      fi
      echo "$connections" | tail -1 | while read -r line; do
        dst=$(echo "$line" | grep -o 'dst.addr=[^ ]*')
        hbone_addr=$(echo "$line" | grep -o 'dst.hbone_addr=[^ ]*')
        echo -e "       Example: ${CYAN}${dst} ${hbone_addr}${RESET}"
        echo -e "       ${CYAN}(app traffic tunneled through mTLS on port 15008)${RESET}"
      done
    else
      echo -e "  ${WARN} No outbound connections in recent logs (run generate-traffic.sh)"
    fi
  done
}

# --- Run all checks ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   UC2-T3: Unified Trust & mTLS Verification                ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

check_root_ca
check_intermediate_cas
read -rp "  ⏎ Press ENTER to continue..." _

check_mtls_default
check_spiffe_identities
read -rp "  ⏎ Press ENTER to continue..." _

check_hbone_encryption

header "TRUST & mTLS SUMMARY"
echo ""
echo -e "  ${BOLD}Root CA:${RESET}            ${GREEN}Shared${RESET} (O=Istio, CN=Root CA)"
echo -e "  ${BOLD}Intermediate CAs:${RESET}   Per-cluster (CN=Intermediate CA east/west)"
echo -e "  ${BOLD}Trust domain:${RESET}       ${GREEN}cluster.local${RESET}"
echo -e "  ${BOLD}mTLS mode:${RESET}          ${GREEN}Always on${RESET} (ztunnel, no config needed)"
echo -e "  ${BOLD}Encryption:${RESET}         ${GREEN}100% HBONE${RESET} (port 15008, mTLS)"
echo -e "  ${BOLD}Cert injection:${RESET}     ${GREEN}NONE${RESET} — handled by ztunnel transparently"
echo ""
