#!/bin/sh
# On-demand backup of one lab-multicluster member (Phase 6.2a): a Backup
# with exactly the spec of its Schedule's template (same namespaces,
# kinds and TTL), waits for it to finish and fails unless it Completed
# with no error. Prints the backup name on the last line. Backs
# `make backup-now LAB_CLUSTER=hub|dev|uat|prod`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/backup/_lib.sh
bk_role >/dev/null
require_tools
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

name="manual-$(date -u +%Y%m%d%H%M%S)"
pkubectl -n "$BK_NAMESPACE" get schedule velero-platform-state -o json \
  | jq --arg n "$name" --arg ns "$BK_NAMESPACE" '{apiVersion: "velero.io/v1", kind: "Backup",
      metadata: {name: $n, namespace: $ns, labels: {"velero.io/schedule-name": "velero-platform-state"}},
      spec: .spec.template}' \
  | pkubectl apply -f - >/dev/null
i=0; phase=""
while [ "$i" -lt 60 ]; do
  phase="$(pkubectl -n "$BK_NAMESPACE" get backup "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Completed|Failed|PartiallyFailed|FailedValidation) break ;; esac
  i=$((i + 1)); sleep 3
done
summary="$(pkubectl -n "$BK_NAMESPACE" get backup "$name" -o json | jq -c '{phase: .status.phase, items: .status.progress.itemsBackedUp, errors: (.status.errors // 0), warnings: (.status.warnings // 0)}')"
echo "backup $name on '$PROJECT_CLUSTER_NAME': $summary"
[ "$phase" = Completed ] && [ "$(printf '%s' "$summary" | jq '.errors')" = 0 ] || { echo "FAIL: backup $name did not complete cleanly" >&2; exit 1; }
echo "$name"
