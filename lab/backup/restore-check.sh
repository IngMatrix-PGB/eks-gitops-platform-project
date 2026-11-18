#!/bin/sh
# Non-destructive restore check (Phase 6.2a): restores the latest completed
# backup of one member into throwaway namespaces (bkcheck-<namespace>,
# via Velero's namespace mapping), compares every restored Secret's data
# with the live one by SHA-256 (values are never printed), then deletes
# exactly those throwaway namespaces. Nothing live is touched. Backs
# `make backup-restore-check LAB_CLUSTER=hub|dev|uat|prod`.
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

nss="$(bk_namespaces "$LAB_CLUSTER")"
cleanup() {
  for ns in $nss; do pkubectl delete namespace "bkcheck-$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; done
}
trap cleanup EXIT INT TERM

backup="$(pkubectl -n "$BK_NAMESPACE" get backups -o json | jq -r '[.items[] | select(.status.phase == "Completed")] | sort_by(.status.completionTimestamp) | last | .metadata.name // empty')"
[ -n "$backup" ] || { echo "FAIL: no completed backup on '$PROJECT_CLUSTER_NAME'" >&2; exit 1; }
name="check-$(date -u +%Y%m%d%H%M%S)"
mapping="$(for ns in $nss; do printf '"%s":"bkcheck-%s",' "$ns" "$ns"; done | sed 's/,$//')"
pkubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${name}
  namespace: ${BK_NAMESPACE}
spec:
  backupName: ${backup}
  includedResources: [secrets]
  namespaceMapping: {${mapping}}
  existingResourcePolicy: none
  restorePVs: false
YAML
i=0; phase=""
while [ "$i" -lt 60 ]; do
  phase="$(pkubectl -n "$BK_NAMESPACE" get restore "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Completed|Failed|PartiallyFailed|FailedValidation) break ;; esac
  i=$((i + 1)); sleep 3
done
[ "$phase" = Completed ] || { echo "FAIL: restore $name of $backup is '$phase'" >&2; exit 1; }

fail=0; n=0
datahash() { pkubectl -n "$1" get secret "$2" -o json | jq -cS '.data' | shasum -a 256 | awk '{print $1}'; }
for ns in $nss; do
  for s in $(pkubectl -n "bkcheck-$ns" get secrets -o jsonpath='{range .items[?(@.type!="kubernetes.io/service-account-token")]}{.metadata.name}{" "}{end}'); do
    n=$((n + 1))
    if [ "$(datahash "bkcheck-$ns" "$s")" = "$(datahash "$ns" "$s")" ]; then
      echo "OK: $ns/$s restored identical (SHA-256 of data)"
    else
      echo "FAIL: $ns/$s restored differs from live" >&2; fail=1
    fi
  done
done
[ "$n" -gt 0 ] || { echo "FAIL: the restore produced no Secret" >&2; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "backup-restore-check: OK - $n Secrets of backup $backup restored identical on '$PROJECT_CLUSTER_NAME' (throwaway namespaces removed)"
