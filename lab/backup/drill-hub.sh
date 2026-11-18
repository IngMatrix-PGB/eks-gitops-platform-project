#!/bin/sh
# Restore drill 2 (Phase 6.2b, ADR-0022): lose the hub and rebuild it from
# Git plus its newest backup, while the spokes keep running. DESTRUCTIVE:
# deletes the hub's kind cluster. Backs `make backup-drill-hub CONFIRM=yes`.
#
#   0. preflight: store running, hub backup status OK, a fresh backup;
#      record SHA-256 of the repository Secret, of each spoke's cluster
#      Secret (its 24h token), of the hub's web-config users, and each
#      spoke's workload pod UIDs; record each token's expiry
#   1. delete the hub cluster
#   2. rebuild: create the hub, Argo CD, Velero (same store key), restore
#      argocd and monitoring Secrets and ConfigMaps (never over a live
#      object), observability (finds the restored credentials), then the
#      hub bootstrap
#   3. converge: every spoke Application Synced/Healthy
#   4. verify: repository and cluster Secrets identical - no spoke was
#      re-registered (if a restored token had expired, the drill fails and
#      says so: that path is a re-registration, not a restore); hub users
#      unchanged; spokes' workloads untouched; each spoke's agent sends
#      with none refused, without reinstalling anything on a spoke; hub
#      metrics and logs from every spoke; backups OK
# Prints the RTO (deletion to every Application green) and each step.
# Needs gh authenticated as the repository owner, like make mc-up.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools
. lab/multicluster/_lib.sh
. scripts/backup/_lib.sh
. scripts/observability/_lib.sh

echo "backup-drill-hub: this DELETES kind cluster eks-gitops-hub and rebuilds it from Git plus its newest backup; the spokes keep running."
[ "${1:-}" = "--confirm" ] || { echo "FAIL: rerun with --confirm (make ... CONFIRM=yes)" >&2; exit 1; }
lab_mc_identity hub || { echo "FAIL: the hub is not up ($LAB_MC_IDENTITY_CASE)" >&2; exit 1; }
bk_store_running || { echo "FAIL: the backup store is not running" >&2; exit 1; }
# The hub bootstrap re-checks the deploy key against GitHub, so the drill
# needs what `make mc-up` needs: gh authenticated as the repository owner
# (for example GH_TOKEN pinned to that account). Checked before anything
# is deleted.
GITOPS_CHECK_ONLY=1 LAB_CLUSTER=hub sh lab/gitops/repo-setup.sh >/dev/null 2>&1 \
  || { echo "FAIL: repository authentication check failed (gh must act as the repository owner, as for make mc-up) - nothing was deleted" >&2; exit 1; }
spokes=""
for s in $LAB_MC_ALL_SPOKES; do lab_mc_identity "$s" && spokes="${spokes:+$spokes }$s"; done
[ -n "$spokes" ] || { echo "FAIL: no spoke is up" >&2; exit 1; }

hk() { ckubectl hub "$@"; }
datahash() { "$1" -n "$2" get secret "$3" -o json 2>/dev/null | jq -cS '.data' | shasum -a 256 | awk '{print $1}'; }
podset() { ckubectl "$1" -n "$1" get pods -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{end}' 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
step() { now="$(date +%s)"; echo "drill: [$1] done in $((now - t_step))s"; t_step="$now"; }

echo "drill: [0] preflight and fresh backup on the hub ..."
LAB_CLUSTER=hub sh lab/backup/status.sh >/dev/null
backup="$(LAB_CLUSTER=hub sh lab/backup/now.sh | tail -1)"
repo_before="$(datahash hk argocd eks-gitops-platform-project-repo)"
users_before="$(hk -n monitoring get secret obs-web-config -o jsonpath='{.data.users}' | shasum -a 256 | awk '{print $1}')"
before=""
for s in $spokes; do
  exp="$(hk -n argocd get secret "spoke-${s}" -o jsonpath='{.metadata.annotations.eks-gitops-lab-lite\.local/token-expires}')"
  before="$before $s:$(datahash hk argocd "spoke-${s}"):$(podset "$s"):$exp"
  echo "OK: spoke-$s cluster Secret recorded; its token expires $exp"
done
echo "OK: backup $backup; hashes recorded"

t0="$(date +%s)"; t_step="$t0"
echo "drill: [1] deleting cluster eks-gitops-hub ..."
LAB_CLUSTER=hub sh lab/kind/destroy.sh >/dev/null
step 1

echo "drill: [2] rebuilding the hub ..."
SPOKES="$(echo "$spokes" | tr ' ' ',')" sh lab/multicluster/create.sh >/dev/null
step "2a cluster"
LAB_CLUSTER=hub sh lab/argocd/install.sh >/dev/null
step "2b Argo CD"
LAB_CLUSTER=hub sh lab/backup/install.sh >/dev/null
i=0; until hk -n "$BK_NAMESPACE" get backup "$backup" >/dev/null 2>&1 || [ "$i" -gt 60 ]; do i=$((i + 1)); sleep 5; done
hk -n "$BK_NAMESPACE" get backup "$backup" >/dev/null 2>&1 || { echo "FAIL: backup $backup not synced from the store" >&2; exit 1; }
step "2c Velero (backup $backup visible from the store)"
restore="drill-$(date -u +%Y%m%d%H%M%S)"
hk apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore}
  namespace: ${BK_NAMESPACE}
spec:
  backupName: ${backup}
  includedNamespaces: [argocd, monitoring]
  includedResources: [secrets, configmaps, roles.rbac.authorization.k8s.io, rolebindings.rbac.authorization.k8s.io]
  existingResourcePolicy: none
  restorePVs: false
YAML
i=0; phase=""
while [ "$i" -lt 60 ]; do
  phase="$(hk -n "$BK_NAMESPACE" get restore "$restore" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Completed|Failed|PartiallyFailed|FailedValidation) break ;; esac
  i=$((i + 1)); sleep 3
done
case "$phase" in
  Completed) : ;;
  PartiallyFailed)
    errs="$(hk -n "$BK_NAMESPACE" get restore "$restore" -o jsonpath='{.status.errors}')"
    [ "${errs:-0}" = 0 ] || { echo "FAIL: restore $restore $phase with $errs errors" >&2; exit 1; } ;;
  *) echo "FAIL: restore $restore is '$phase'" >&2; exit 1 ;;
esac
step "2d restore ($restore: $phase)"
make -s obs-install LAB_CLUSTER=hub 2>&1 | grep -E "FAIL" || true
step "2e observability"
LAB_CLUSTER=hub sh lab/gitops/bootstrap.sh >/dev/null
step "2f hub bootstrap"

echo "drill: [3] converging ..."
for s in $spokes; do
  i=0; app=""
  while [ "$i" -lt 60 ]; do
    app="$(hk -n argocd get application "platform-smoke-${s}" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
    [ "$app" = Synced/Healthy ] && break
    i=$((i + 1)); sleep 10
  done
  [ "$app" = Synced/Healthy ] || { echo "FAIL: platform-smoke-${s} is '$app'" >&2; exit 1; }
done
step 3
rto=$(( $(date +%s) - t0 ))

echo "drill: [4] verifying ..."
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
[ "$(datahash hk argocd eks-gitops-platform-project-repo)" = "$repo_before" ] && ok "repository Secret restored identical (SHA-256)" || bad "repository Secret differs"
users_after="$(hk -n monitoring get secret obs-web-config -o jsonpath='{.data.users}' | shasum -a 256 | awk '{print $1}')"
[ "$users_after" = "$users_before" ] && ok "hub user list restored identical (no spoke credential rotated)" || bad "hub user list changed"
for entry in $before; do
  s="$(echo "$entry" | cut -d: -f1)"; csec="$(echo "$entry" | cut -d: -f2)"; pods="$(echo "$entry" | cut -d: -f3)"
  [ "$(datahash hk argocd "spoke-${s}")" = "$csec" ] && ok "spoke-$s cluster Secret restored identical: Argo CD reconnected without re-registration" || bad "spoke-$s cluster Secret differs (re-registered?)"
  [ "$(podset "$s")" = "$pods" ] && ok "spoke '$s' workload untouched (same pods)" || bad "spoke '$s' workload pods changed"
  LAB_CLUSTER="$s" STATUS_WINDOW=60 sh lab/observability/status.sh >/dev/null 2>&1 && ok "spoke '$s' agent sends to the rebuilt hub, none refused (nothing reinstalled on the spoke)" || bad "spoke '$s' observability status failed"
  # Logs: the rebuilt Loki starts empty (emptyDir, ADR-0021) and a spoke
  # sends only new lines, so the proof is that the rebuilt gateway accepts
  # the spoke's unchanged credential.
  pwf="$(mktemp)"; chmod 600 "$pwf"
  ckubectl "$s" -n "$OBS_LOGS_NAMESPACE" get secret "$OBS_SECRET_LOGS_PUSH" -o jsonpath='{.data.password}' | base64 -d > "$pwf"
  obs_hub_wait hk "spoke-${s}" "$pwf" accept 60 loki >/dev/null && ok "rebuilt Loki gateway accepts spoke-$s's unchanged log credential" || bad "rebuilt Loki gateway refuses spoke-$s"
  rm -f "$pwf"
done
expect="hub $(for s in $spokes; do printf 'spoke-%s ' "$s"; done)"
obs_out="$(mktemp)"
LAB_CLUSTER=hub EXPECT_CLUSTERS="$expect" EXPECT_LOG_CLUSTERS="" sh lab/observability/status.sh > "$obs_out" 2>&1 && ok "hub observability OK: metrics from $expect, rules healthy, Grafana datasources" || { bad "hub observability status failed"; grep FAIL "$obs_out" >&2; }
rm -f "$obs_out"
LAB_CLUSTER=hub sh lab/backup/status.sh >/dev/null 2>&1 && ok "backups on the hub OK (same store key)" || bad "hub backup status failed"

echo ""
echo "drill: RTO ${rto}s (deletion of eks-gitops-hub to every spoke Application Synced/Healthy)"
[ "$fail" -eq 0 ] || { echo "backup-drill-hub: FAILED"; exit 1; }
echo "backup-drill-hub: OK"
