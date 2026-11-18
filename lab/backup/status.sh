#!/bin/sh
# Read-only backup status of one lab-multicluster member (Phase 6.2a).
# Backs `make backup-status LAB_CLUSTER=hub|dev|uat|prod`: release deployed,
# Velero Ready, BackupStorageLocation Available, and the newest completed
# backup younger than 13 hours (two missed 6-hour runs plus one).
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

fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

if phelm status "$BK_RELEASE" -n "$BK_NAMESPACE" -o json 2>/dev/null | grep -q '"status":"deployed"'; then ok "release '$BK_RELEASE' deployed"; else bad "release '$BK_RELEASE' not deployed"; fi
av="$(pkubectl -n "$BK_NAMESPACE" get deployment velero -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
[ "${av:-0}" -ge 1 ] 2>/dev/null && ok "Velero Available" || bad "Velero not Available"
bsl="$(pkubectl -n "$BK_NAMESPACE" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[ "$bsl" = Available ] && ok "BackupStorageLocation 'default' Available ($(bk_bucket "$LAB_CLUSTER"))" || bad "BackupStorageLocation 'default' is '${bsl:-absent}'"
latest="$(pkubectl -n "$BK_NAMESPACE" get backups -o json | jq -r '[.items[] | select(.status.phase == "Completed")] | sort_by(.status.completionTimestamp) | last | if . == null then "" else "\(.metadata.name) \(.status.completionTimestamp) \(.status.progress.itemsBackedUp // 0)" end')"
if [ -z "$latest" ]; then
  bad "no completed backup"
else
  set -- $latest
  age=$(( $(date -u +%s) - $(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$2" +%s 2>/dev/null || date -u -d "$2" +%s) ))
  [ "$age" -lt $((13 * 3600)) ] && ok "newest completed backup $1: ${3} items, $((age / 60)) min old" || bad "newest completed backup $1 is $((age / 3600)) h old"
fi
[ "$fail" -eq 0 ] || { echo "backup-status: FAILED ($PROJECT_CLUSTER_NAME)"; exit 1; }
echo "backup-status: OK ($PROJECT_CLUSTER_NAME)"
