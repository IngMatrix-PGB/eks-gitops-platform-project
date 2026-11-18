#!/bin/sh
# Explicit, confirmed upgrade of an installed Argo CD to the values in
# lab/argocd/values-lab.yaml (Phase 6.3a, ADR-0023). Backs
# `make argocd-upgrade [LAB_CLUSTER=hub] CONFIRM=yes`.
#
# make argocd-install keeps refusing any drift on purpose; this is the one
# path that applies a reviewed values change to a running Argo CD:
#   - same pinned chart only (a chart change is a different decision);
#     a release not "deployed" is refused;
#   - already at the values and manifest: no-op;
#   - prints which rendered objects change (kind/name; for ConfigMaps the
#     line diff - no Secret content is ever printed) and stops unless
#     --confirm;
#   - helm upgrade with exactly install's arguments and description, so
#     make argocd-install is a no-op afterwards; CRDs are kept
#     (crds.keep in the values, and helm upgrade never deletes CRDs);
#   - afterwards the live manifest must equal the offline render, or the
#     release is rolled back to the previous revision automatically.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/argocd/_lib.sh
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }
require_helm
require_argocd_chart

if check_argocd_install_identity >/dev/null 2>&1; then
  echo "OK: Argo CD on '$PROJECT_CLUSTER_NAME' already at the pinned chart, values and manifest - no-op"
  exit 0
fi
case "$ARGOCD_INSTALL_CASE" in
  values_drift|manifest_drift) : ;;
  absent) echo "FAIL: Argo CD is not installed on '$PROJECT_CLUSTER_NAME' - use make argocd-install" >&2; exit 1 ;;
  chart_drift) echo "FAIL: the installed chart is not the pinned $ARGOCD_CHART_VERSION - a chart change is not a values upgrade" >&2; exit 1 ;;
  *) echo "FAIL: release state '$ARGOCD_INSTALL_CASE' - refusing" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
phelm template "$ARGOCD_RELEASE_NAME" "$ARGOCD_CHART_TGZ" --namespace "$ARGOCD_NAMESPACE" \
  -f "$ARGOCD_VALUES_FILE" --no-hooks > "$work/desired.yaml"
phelm get manifest "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE" > "$work/live.yaml"

# Per-object comparison by kind/name; ConfigMap bodies diffed line by
# line. YAML is parsed with the pinned yq, never PyYAML.
yq_bin=".tools/bin/yq"
[ -x "$yq_bin" ] || { echo "FAIL: $yq_bin not found - run 'make tools-install'" >&2; exit 1; }
"$yq_bin" eval-all -o=json '[.]' "$work/live.yaml" > "$work/live.json"
"$yq_bin" eval-all -o=json '[.]' "$work/desired.yaml" > "$work/desired.json"
python3 -I - "$work/live.json" "$work/desired.json" <<'PY'
import difflib, json, sys
def load(p):
    out = {}
    for d in json.load(open(p)):
        if d: out[(d["kind"], d["metadata"]["name"])] = d
    return out
live, desired = load(sys.argv[1]), load(sys.argv[2])
changed = 0
for key in sorted(set(live) | set(desired)):
    a, b = live.get(key), desired.get(key)
    if a == b: continue
    changed += 1
    kind, name = key
    state = "added" if a is None else "removed" if b is None else "changed"
    print(f"  {state}: {kind}/{name}")
    if kind == "ConfigMap" and a and b:
        for k in sorted(set(a.get("data") or {}) | set(b.get("data") or {})):
            x = str((a.get("data") or {}).get(k, "")).splitlines()
            y = str((b.get("data") or {}).get(k, "")).splitlines()
            for line in difflib.unified_diff(x, y, f"live {k}", f"desired {k}", lineterm="", n=1):
                print("      " + line)
print(f"argocd-upgrade: {changed} object(s) differ")
PY

if [ "${1:-}" != "--confirm" ]; then
  echo "argocd-upgrade: nothing applied - rerun with CONFIRM=yes to apply the change above"
  exit 1
fi

prev_rev="$(phelm history "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE" -o json | jq -r 'map(select(.status == "deployed")) | last | .revision')"
values_sha="$(argocd_values_fingerprint)"
echo "argocd-upgrade: upgrading '$ARGOCD_RELEASE_NAME' on '$PROJECT_CLUSTER_NAME' (from revision $prev_rev) ..."
if ! phelm upgrade --install "$ARGOCD_RELEASE_NAME" "$ARGOCD_CHART_TGZ" \
      --namespace "$ARGOCD_NAMESPACE" -f "$ARGOCD_VALUES_FILE" \
      --description "values-sha256:${values_sha}" --wait --timeout 5m >/dev/null \
   || ! compare_desired_vs_live_manifest; then
  echo "FAIL: upgrade failed or the live manifest does not match the render - rolling back to revision $prev_rev" >&2
  phelm rollback "$ARGOCD_RELEASE_NAME" "$prev_rev" -n "$ARGOCD_NAMESPACE" --wait --timeout 5m >/dev/null || true
  exit 1
fi
check_argocd_install_identity >/dev/null 2>&1 || { echo "FAIL: after the upgrade Argo CD's identity is '$ARGOCD_INSTALL_CASE', not match" >&2; exit 1; }
echo "argocd-upgrade: OK - make argocd-install is a no-op again on '$PROJECT_CLUSTER_NAME'"
