#!/bin/bash

set -euo pipefail

PORT="${PORT:-8443}"
CERT="${CERT:-/etc/tls/tls.crt}"
KEY="${KEY:-/etc/tls/tls.key}"

# Keep this UC focused on custom CA trust; TLS version can remain modern.
TLS_FLAG="${TLS_FLAG:--tls1_2}"
CIPHER="${CIPHER:-ECDHE-RSA-AES256-GCM-SHA384}"

if [[ ! -f "${CERT}" || ! -f "${KEY}" ]]; then
  echo "ERROR: missing cert/key. Expecting:"
  echo "  CERT=${CERT}"
  echo "  KEY=${KEY}"
  exit 1
fi

echo "Starting custom-cert TLS server on :${PORT}"
echo "TLS flag: ${TLS_FLAG}"
echo "Cipher:   ${CIPHER}"

exec openssl s_server \
  -accept "${PORT}" \
  -cert "${CERT}" -key "${KEY}" \
  ${TLS_FLAG} \
  -cipher "${CIPHER}" \
  -www

