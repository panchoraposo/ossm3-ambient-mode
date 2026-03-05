#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INVENTORY_FILE="${INVENTORY_FILE:-inventory.yaml}"
PLAYBOOK="${PLAYBOOK:-ansible/playbooks/install-multi-cluster-istio129.yaml}"
ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" "$@"
