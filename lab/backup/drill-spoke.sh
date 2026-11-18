#!/bin/sh
# Restore drill 1 (Phase 6.2b, ADR-0022): lose one spoke and rebuild it
# from Git plus its newest backup. DESTRUCTIVE: deletes the spoke's kind
# cluster. Backs `make backup-drill-spoke SPOKE=<dev|uat|prod> CONFIRM=yes`.
#
#   0. preflight: store running, the spoke's backup status OK, a fresh
#      backup taken; record SHA-256 of the ESO source Secret, of the
#      workload's ESO-built Secret, of the hub's user list, and the
#      other spokes' workload pod UIDs (nothing is printed but hashes)
#   1. delete the spoke's cluster
#   2. rebuild in the order that keeps the old state: create the cluster,
#      register it with the hub, ESO, metrics-server, Velero (same store
#      key), then restore the backup's Secrets, ConfigMaps, Roles and
#      RoleBindings (never over a live object) - before anything could
#      generate a new source value or credential - and only then let
#      Argo CD see ESO's kinds (cluster cache refresh)
#   3. observability on the spoke: it finds the restored credential, so
#      the hub gets no new user
#   4. converge: Argo CD Synced/Healthy, workload Ready
#   5. verify: same source and workload Secret hashes, same hub user
#      list, metrics and logs flowing with the restored credential, the
#      other spokes untouched; `make mc-up SPOKES=<spoke>` is then a no-op
#      for the source Secret
# Prints the RTO (deletion to green) and each step's duration.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
spoke="${1:-}"
case "$spoke" in dev|uat|prod) : ;; *) echo "usage: $0 <dev|uat|prod> --confirm" >&2; exit 2 ;; esac
. scripts/lab/_lib.sh
require_repo_root
require_tools
. lab/multicluster/_lib.sh
. scripts/backup/_lib.sh

echo "backup-drill-spoke: this DELETES kind cluster eks-gitops-${spoke} and rebuilds it from Git plus its newest backup."
[ "${2:-}" = "--confirm" ] || { echo "FAIL: rerun with --confirm (make ... CONFIRM=yes)" >&2; exit 1; }
lab_mc_identity "$spoke" || { echo "FAIL: spoke '$spoke' is not up ($LAB_MC_IDENTITY_CASE)" >&2; exit 1; }
lab_mc_identity hub || { echo "FAIL: the hub is not up" >&2; exit 1; }
bk_store_running || { echo "FAIL: the backup store is not running" >&2; exit 1; }

others=""
for s in $LAB_MC_ALL_SPOKES; do
  [ "$s" = "$spoke" ] && continue
  lab_mc_identity "$s" && others="${others:+$others }$s"
done

hk() { ckubectl hub "$@"; }
sk() { ckubectl "$spoke" "$@"; }
datahash() { # $1=kubectl-fn $2=namespace $3=secret
  "$1" -n "$2" get secret "$3" -o json 2>/dev/null | jq -cS '.data' | shasum -a 256 | awk '{print $1}'
}
podset() { ckubectl "$1" -n "$1" get pods -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{end}' 2>/dev/null; }
step() { now="$(date +%s)"; echo "drill: [$1] done in $((now - t_step))s"; t_step="$now"; }

workload_secret="platform-smoke-${spoke}-standard-workload-secret"
echo "drill: [0] preflight and fresh backup on '$spoke' ..."
LAB_CLUSTER="$spoke" sh lab/backup/status.sh >/dev/null
backup="$(LAB_CLUSTER="$spoke" sh lab/backup/now.sh | tail -1)"
src_before="$(datahash sk "eso-source-${spoke}" "local-backend-${spoke}")"
wl_before="$(datahash sk "$spoke" "$workload_secret")"
users_before="$(hk -n monitoring get secret obs-web-config -o jsonpath='{.data.users}' | shasum -a 256 | awk '{print $1}')"
others_before=""; for s in $others; do others_before="$others_before $s:$(podset "$s" | shasum -a 256 | awk '{print $1}')"; done
echo "OK: backup $backup; hashes recorded (source, workload Secret, hub users, other spokes' pods)"

t0="$(date +%s)"; t_step="$t0"
echo "drill: [1] deleting cluster eks-gitops-${spoke} ..."
LAB_CLUSTER="$spoke" sh lab/kind/destroy.sh >/dev/null
step 1

echo "drill: [2] rebuilding '$spoke' ..."
SPOKES="$spoke" sh lab/multicluster/create.sh >/dev/null
step "2a cluster"
sh lab/multicluster/spoke-register.sh "$spoke" >/dev/null
step "2b register"
LAB_CLUSTER="$spoke" sh lab/eso/install.sh >/dev/null
step "2c ESO"
LAB_CLUSTER="$spoke" sh lab/metrics-server/install.sh >/dev/null
step "2d metrics-server"
LAB_CLUSTER="$spoke" sh lab/backup/install.sh >/dev/null
i=0; until sk -n "$BK_NAMESPACE" get backup "$backup" >/dev/null 2>&1 || [ "$i" -gt 60 ]; do i=$((i + 1)); sleep 5; done
sk -n "$BK_NAMESPACE" get backup "$backup" >/dev/null 2>&1 || { echo "FAIL: backup $backup not synced from the store" >&2; exit 1; }
step "2e Velero (backup $backup visible from the store)"
restore="drill-$(date -u +%Y%m%d%H%M%S)"
nss_yaml="$(for ns in $(bk_namespaces "$spoke"); do printf '%s, ' "$ns"; done | sed 's/, $//')"
sk apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore}
  namespace: ${BK_NAMESPACE}
spec:
  backupName: ${backup}
  includedNamespaces: [${nss_yaml}]
  includedResources: [secrets, configmaps, roles.rbac.authorization.k8s.io, rolebindings.rbac.authorization.k8s.io]
  existingResourcePolicy: none
  restorePVs: false
YAML
i=0; phase=""
while [ "$i" -lt 60 ]; do
  phase="$(sk -n "$BK_NAMESPACE" get restore "$restore" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Completed|Failed|PartiallyFailed|FailedValidation) break ;; esac
  i=$((i + 1)); sleep 3
done
case "$phase" in
  Completed) : ;;
  PartiallyFailed)
    # kube-root-ca.crt exists in every namespace and is skipped, which
    # Velero reports as a warning, not an error; anything else fails.
    errs="$(sk -n "$BK_NAMESPACE" get restore "$restore" -o jsonpath='{.status.errors}')"
    [ "${errs:-0}" = 0 ] || { echo "FAIL: restore $restore $phase with $errs errors" >&2; exit 1; } ;;
  *) echo "FAIL: restore $restore is '$phase'" >&2; exit 1 ;;
esac
step "2f restore ($restore: $phase)"
# The spoke was re-registered before ESO's CRDs existed, so Argo CD's
# cluster cache holds no schema for them (ComparisonError on the
# ExternalSecret). A change to the cluster Secret makes Argo CD rebuild
# that cache; done after the restore, so the SecretStore is created only
# once its source Secret and reader RBAC exist.
hk -n argocd annotate secret "spoke-${spoke}" "eks-gitops-lab-lite.local/cache-refreshed=$(date -u +%Y%m%dT%H%M%SZ)" --overwrite >/dev/null
step "2g Argo CD cluster cache refreshed"

echo "drill: [3] observability on '$spoke' ..."
make -s obs-install LAB_CLUSTER="$spoke" 2>&1 | grep -E "credential|FAIL" || true
step "3 observability"

echo "drill: [4] converging ..."
i=0; app=""
while [ "$i" -lt 60 ]; do
  app="$(hk -n argocd get application "platform-smoke-${spoke}" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [ "$app" = Synced/Healthy ] && break
  hk -n argocd annotate application "platform-smoke-${spoke}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
  i=$((i + 1)); sleep 10
done
[ "$app" = Synced/Healthy ] || { echo "FAIL: platform-smoke-${spoke} is '$app'" >&2; exit 1; }
sk -n "$spoke" rollout status "deploy/platform-smoke-${spoke}-standard-workload" --timeout=180s >/dev/null
step 4
rto=$(( $(date +%s) - t0 ))

echo "drill: [5] verifying ..."
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
[ "$(datahash sk "eso-source-${spoke}" "local-backend-${spoke}")" = "$src_before" ] && ok "ESO source Secret restored identical (SHA-256)" || bad "ESO source Secret differs from before"
[ "$(datahash sk "$spoke" "$workload_secret")" = "$wl_before" ] && ok "workload Secret rebuilt by ESO identical (SHA-256)" || bad "workload Secret differs from before"
users_after="$(hk -n monitoring get secret obs-web-config -o jsonpath='{.data.users}' | shasum -a 256 | awk '{print $1}')"
[ "$users_after" = "$users_before" ] && ok "hub user list unchanged (no new credential for spoke-${spoke})" || bad "hub user list changed"
for pair in $others_before; do
  s="${pair%%:*}"; h="${pair#*:}"
  [ "$(podset "$s" | shasum -a 256 | awk '{print $1}')" = "$h" ] && ok "spoke '$s' untouched (same workload pods)" || bad "spoke '$s' workload pods changed"
done
LAB_CLUSTER="$spoke" STATUS_WINDOW=60 sh lab/observability/status.sh >/dev/null 2>&1 && ok "observability on '$spoke' OK (samples sent, none refused; log agent clean)" || bad "observability status on '$spoke' failed"
LAB_CLUSTER="$spoke" sh lab/backup/status.sh >/dev/null 2>&1 && ok "backups on '$spoke' OK (same store key)" || bad "backup status on '$spoke' failed"
SPOKES="$spoke" sh lab/multicluster/up.sh 2>&1 | grep -q "source Secret for '$spoke' already present - not read, not changed" \
  && ok "make mc-up SPOKES=$spoke afterwards: source Secret left as restored" || bad "mc-up did not leave the source Secret alone"

echo ""
echo "drill: RTO ${rto}s (deletion of eks-gitops-${spoke} to Argo CD Synced/Healthy with the workload Ready)"
[ "$fail" -eq 0 ] || { echo "backup-drill-spoke: FAILED"; exit 1; }
echo "backup-drill-spoke: OK ($spoke)"
