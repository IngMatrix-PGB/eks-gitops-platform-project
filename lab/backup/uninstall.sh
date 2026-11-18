#!/bin/sh
# Idempotent removal of Velero from one lab-multicluster member (Phase
# 6.2a). Backs `make backup-uninstall LAB_CLUSTER=hub|dev|uat|prod`.
# Removes the release (and with it the Schedule, BackupStorageLocation,
# RBAC and NetworkPolicy it owns) and the credential Secret. Kept, by
# design: Velero's CRDs (installed from the chart's crds/ directory, which
# Helm never deletes), the namespace, and - in the store - this cluster's
# bucket, its backups and its key, so the cluster can be rebuilt and
# restored.
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
require_helm
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

if phelm status "$BK_RELEASE" -n "$BK_NAMESPACE" >/dev/null 2>&1; then
  phelm uninstall "$BK_RELEASE" -n "$BK_NAMESPACE" --wait --timeout 5m >/dev/null
  echo "OK: release '$BK_RELEASE' uninstalled from '$PROJECT_CLUSTER_NAME'"
else
  echo "OK: release '$BK_RELEASE' already absent on '$PROJECT_CLUSTER_NAME' - no-op"
fi
pkubectl -n "$BK_NAMESPACE" delete secret "$BK_SECRET" --ignore-not-found >/dev/null
echo "OK: secret/$BK_SECRET absent"
echo "backup-uninstall: OK - backups and key for '$LAB_CLUSTER' kept in the store"
