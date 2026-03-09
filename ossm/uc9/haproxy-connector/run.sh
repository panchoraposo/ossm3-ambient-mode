#!/bin/bash

set -euo pipefail

CFG="${CFG:-/etc/haproxy/haproxy.cfg}"

if [[ ! -f "${CFG}" ]]; then
  echo "ERROR: missing haproxy config at ${CFG}"
  exit 1
fi

echo "Starting HAProxy with ${CFG}"
exec haproxy -f "${CFG}" -db

