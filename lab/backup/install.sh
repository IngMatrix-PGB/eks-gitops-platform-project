#!/bin/sh
# Fail-closed, idempotent install of Velero on one lab-multicluster member
# (Phase 6.2a, ADR-0022). Backs `make backup-install LAB_CLUSTER=hub|dev|uat|prod`.
#   - the store must be running (make backup-store-up);
#   - the store gets (or keeps) this cluster's S3 user and bucket; the key
#     lives in the store's IAM file, so a rebuilt cluster gets the same one
#     and can read its old backups;
#   - namespace velero (Pod Security restricted), Secret with the key in
#     AWS credentials-file form, release velero (chart pinned by sha256,
#     images by digest), then waits for the BackupStorageLocation to be
#     Available.
# Same chart and values -> no helm call; another chart or a release not
# "deployed" -> fail closed. No key is printed or put on argv.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. lab/multicluster/_lib.sh
. scripts/backup/_lib.sh
role="$(bk_role)"
require_tools
require_helm
require_bk_chart
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }
bk_store_running || { echo "FAIL: the backup store is not running - run 'make backup-store-up' first" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
umask 077

if ! phelm status "$BK_RELEASE" -n "$BK_NAMESPACE" >/dev/null 2>&1; then
  free_mib="$(lab_mc_docker_free_mib)" || { echo "FAIL: could not read Docker memory" >&2; exit 1; }
  if [ "${BK_SKIP_MEMORY_CHECK:-}" != "1" ] && [ "$free_mib" -lt "$BK_MIB" ]; then
    echo "FAIL: backup-install: Docker has ~${free_mib} MiB free; Velero needs ~${BK_MIB} MiB. Nothing was installed." >&2; exit 1
  fi
  echo "OK: memory check - ~${free_mib} MiB free, floor ${BK_MIB} MiB"
fi

case "$(bk_store_ensure_cluster "$LAB_CLUSTER")" in
  created) echo "OK: store user velero-${LAB_CLUSTER} created; bucket $(bk_bucket "$LAB_CLUSTER") owned by it" ;;
  kept) echo "OK: store user velero-${LAB_CLUSTER} already present (kept); bucket $(bk_bucket "$LAB_CLUSTER") owned by it" ;;
  *) echo "FAIL: could not set up the store user for ${LAB_CLUSTER}" >&2; exit 1 ;;
esac

pkubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${BK_NAMESPACE}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.36
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
YAML

mkdir -p "$work/cred"
{ printf '[default]\naws_access_key_id=velero-%s\naws_secret_access_key=' "$LAB_CLUSTER"; bk_store_secret "$LAB_CLUSTER"; printf '\n'; } > "$work/cred/cloud"
pkubectl -n "$BK_NAMESPACE" create secret generic "$BK_SECRET" --from-file="$work/cred" --dry-run=client -o yaml | pkubectl apply -f - >/dev/null
rm -rf "$work/cred"

bk_write_velero_values "$LAB_CLUSTER" "$work/values.yaml"
sha="$(shasum -a 256 "$work/values.yaml" | awk '{print $1}')"
if phelm status "$BK_RELEASE" -n "$BK_NAMESPACE" >/dev/null 2>&1; then
  json="$(phelm status "$BK_RELEASE" -n "$BK_NAMESPACE" -o json 2>/dev/null | sed 's/,"notes":.*//')"
  st="$(printf '%s' "$json" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
  desc="$(printf '%s' "$json" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"
  chart="$(phelm list -n "$BK_NAMESPACE" -o json 2>/dev/null | tr '{' '\n' | grep "\"name\":\"${BK_RELEASE}\"" | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')"
  [ "$chart" = "velero-${BK_VELERO_CHART_VERSION}" ] || { echo "FAIL: release '$BK_RELEASE' runs chart '$chart', not velero-${BK_VELERO_CHART_VERSION} - refusing to reconcile automatically" >&2; exit 1; }
  [ "$st" = deployed ] || { echo "FAIL: release '$BK_RELEASE' status '$st' is not 'deployed' - refusing to reconcile automatically" >&2; exit 1; }
  if [ "$desc" = "values-sha256:${sha}" ]; then
    echo "OK: release '$BK_RELEASE' already at the pinned chart and values on '$PROJECT_CLUSTER_NAME' - no-op"
  else
    echo "backup-install: values changed - upgrading"
    phelm upgrade --install "$BK_RELEASE" "$BK_VELERO_CHART_TGZ" -n "$BK_NAMESPACE" -f "$work/values.yaml" \
      --description "values-sha256:${sha}" --wait --timeout 5m >/dev/null
  fi
else
  echo "backup-install: installing release '$BK_RELEASE' (velero-${BK_VELERO_CHART_VERSION}) on '$PROJECT_CLUSTER_NAME'"
  phelm upgrade --install "$BK_RELEASE" "$BK_VELERO_CHART_TGZ" -n "$BK_NAMESPACE" -f "$work/values.yaml" \
    --description "values-sha256:${sha}" --wait --timeout 5m >/dev/null
fi

i=0; phase=""
while [ "$i" -lt 36 ]; do
  phase="$(pkubectl -n "$BK_NAMESPACE" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = Available ] && break
  i=$((i + 1)); sleep 5
done
[ "$phase" = Available ] || { echo "FAIL: BackupStorageLocation 'default' is '${phase:-unknown}', not Available" >&2; exit 1; }
echo "OK: BackupStorageLocation 'default' Available ($(bk_bucket "$LAB_CLUSTER") at $BK_STORE_URL)"
echo "backup-install: OK ($role on '$PROJECT_CLUSTER_NAME')"
