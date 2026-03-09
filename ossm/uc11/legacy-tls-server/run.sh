#!/bin/bash

set -euo pipefail

PORT="${PORT:-8443}"
HOSTNAME_CN="${HOSTNAME_CN:-legacy.bank.demo}"

# Keep TLS 1.0 + legacy cipher to simulate old stacks.
TLS_FLAG="${TLS_FLAG:--tls1}"
CIPHER="${CIPHER:-ECDHE-RSA-AES256-SHA}"

echo "Generating self-signed cert (CN=${HOSTNAME_CN})..."
mkdir -p /tmp/tls
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/tls/key.pem -out /tmp/tls/cert.pem \
  -days 365 -subj "/CN=${HOSTNAME_CN}" >/dev/null 2>&1

echo "Starting legacy TLS server on :${PORT}"
echo "TLS flag: ${TLS_FLAG}"
echo "Cipher:   ${CIPHER}"

exec openssl s_server \
  -accept "${PORT}" \
  -cert /tmp/tls/cert.pem -key /tmp/tls/key.pem \
  ${TLS_FLAG} \
  -cipher "${CIPHER}" \
  -www -msg

