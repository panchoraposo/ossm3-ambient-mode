#!/bin/bash
#
# UC11: Special Ciphers — Connectivity Link (Kuadrant) value add
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export UC_ID="UC11"
export UC_TITLE="Special Ciphers"
export UC_VARIANT="${UC_VARIANT:-Connectivity Link (Kuadrant)}"
export UC_DIR="${UC_DIR:-ossm/uc11}"
export RUN_HINT="./ossm/uc11-kuadrant-verify.sh"

exec "${SCRIPT_DIR}/uc11-t2-verify.sh" "$@"

