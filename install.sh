#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INVENTORY_FILE="${INVENTORY_FILE:-inventory.yaml}"
ansible-playbook -i "$INVENTORY_FILE" ./ansible/playbooks/install.yaml "$@"