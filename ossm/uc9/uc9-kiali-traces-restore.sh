#!/bin/bash
#
# Restore Kiali configmap from UC9 demo backup.
#
# Usage:
#   bash ossm/uc9/uc9-kiali-traces-restore.sh
#

set -euo pipefail

KIALI_CTX="${KIALI_CTX:-acm}"
KIALI_NS="${KIALI_NS:-istio-system}"
BACKUP_CM="${BACKUP_CM:-uc9-kiali-config-backup}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

need_cmd oc

cfg="$(oc --context "${KIALI_CTX}" -n "${KIALI_NS}" get cm "${BACKUP_CM}" -o jsonpath='{.data.config\\.yaml}' 2>/dev/null || true)"
if [[ -z "${cfg}" ]]; then
  echo "Backup ConfigMap ${KIALI_NS}/${BACKUP_CM} not found or empty." >&2
  echo "Nothing to restore." >&2
  exit 1
fi

echo "Restoring Kiali configmap on context=${KIALI_CTX} ns=${KIALI_NS} from ${BACKUP_CM}..."
oc --context "${KIALI_CTX}" -n "${KIALI_NS}" patch cm kiali --type merge \
  -p "$(python3 - <<PY
import json,sys
data={"data":{"config.yaml":"""${cfg}""" }}
print(json.dumps(data))
PY
)" >/dev/null

oc --context "${KIALI_CTX}" -n "${KIALI_NS}" rollout restart deploy/kiali >/dev/null 2>&1 || true
oc --context "${KIALI_CTX}" -n "${KIALI_NS}" rollout status deploy/kiali --timeout=180s >/dev/null 2>&1 || true

echo "Done. (You may delete the backup configmap if you want.)"

