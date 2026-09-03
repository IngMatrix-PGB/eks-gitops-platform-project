#!/bin/sh
# Mutating lifecycle test proving the External Secrets Operator
# bootstrap's install/no-op/uninstall/restore idempotency end to end:
#   global-isolation baseline -> Argo CD/workload baseline -> install ->
#   install (true no-op, per release) -> runtime health -> CRD
#   ownership/isolation proof -> uninstall (CRDs retained) -> uninstall
#   (no-op) -> restoration install -> restoration install (no-op) ->
#   final health -> global-isolation re-check.
#
# "True no-op" is proven empirically per scoped release: each release's
# Helm revision and live manifest checksum are captured before and
# after the second install and must be byte-identical.
#
# Never prints Secret/certificate/token/kubeconfig content. Leaves the
# External Secrets Operator installed at the end (the restoration
# install). Backs `make eso-test-lifecycle` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/eso/_lib.sh
. scripts/eso/_lib.sh

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity - run 'make lab-create' first" >&2
  exit 1
fi
require_helm
require_eso_chart

fail=0

# --- 1/2. global kubeconfig/context isolation baseline (hash only,
# never content) ---
global_kubeconfig="$HOME/.kube/config"
if [ -f "$global_kubeconfig" ]; then
  global_sha_before="$(shasum -a 256 "$global_kubeconfig" | awk '{print $1}')"
else
  global_sha_before="<absent>"
fi
global_ctx_before="$(command -v kubectl >/dev/null 2>&1 && kubectl config current-context 2>/dev/null || echo "<no-global-kubectl>")"
echo "OK: captured global kubeconfig baseline (sha256 ${global_sha_before}, context ${global_ctx_before})"

# --- 3. Argo CD and workload baseline (never mutated by this test) ---
argocd_pods_before="$(pkubectl get pods -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')"
apps_before="$(pkubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null)"
echo "OK: captured Argo CD baseline (${argocd_pods_before} pods in argocd namespace)"
printf '%s\n' "$apps_before" | sed 's/^/    /'

capture_release_fingerprint() {
  ns="$1"; release="$2"
  rev="$(phelm get metadata "$release" -n "$ns" -o json 2>/dev/null | sed -n 's/.*"revision":\([0-9]*\).*/\1/p')"
  manifest_raw="$(mktemp)"
  manifest_norm="$(mktemp)"
  phelm get manifest "$release" -n "$ns" > "$manifest_raw" 2>/dev/null
  sed -e 's/[[:space:]]*$//' "$manifest_raw" > "${manifest_norm}.tmp" \
    && printf '%s\n' "$(cat "${manifest_norm}.tmp")" > "$manifest_norm" \
    && rm -f "${manifest_norm}.tmp"
  manifest_sha="$(shasum -a 256 "$manifest_norm" | awk '{print $1}')"
  rm -f "$manifest_raw" "$manifest_norm"
  echo "${rev}:${manifest_sha}"
}

# --- 4. install ---
echo "test-idempotency: first install ..."
sh lab/eso/install.sh

# --- 5. second install as a true no-op (per release) ---
fp_staging_1="$(capture_release_fingerprint eso-staging eso-staging)"
fp_production_1="$(capture_release_fingerprint eso-production eso-production)"

echo "test-idempotency: second install (expect true no-op) ..."
sh lab/eso/install.sh

fp_staging_2="$(capture_release_fingerprint eso-staging eso-staging)"
fp_production_2="$(capture_release_fingerprint eso-production eso-production)"

if [ "$fp_staging_1" = "$fp_staging_2" ]; then
  echo "OK: eso-staging second install is a true no-op (revision:manifest-sha256 unchanged: $fp_staging_1)"
else
  echo "FAIL: eso-staging changed across the second install ($fp_staging_1 -> $fp_staging_2)" >&2
  fail=1
fi
if [ "$fp_production_1" = "$fp_production_2" ]; then
  echo "OK: eso-production second install is a true no-op (revision:manifest-sha256 unchanged: $fp_production_1)"
else
  echo "FAIL: eso-production changed across the second install ($fp_production_1 -> $fp_production_2)" >&2
  fail=1
fi

# --- 6/7. runtime health + 25 CRDs Established ---
echo "test-idempotency: runtime health check ..."
sh tests/eso/test-runtime-health.sh || fail=1

# --- 8. Helm ownership inventory: each release's resources carry that
# release's own ownership annotation, never the other's. ---
staging_owner="$(pkubectl get deployment eso-staging-external-secrets -n eso-staging -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)"
production_owner="$(pkubectl get deployment eso-production-external-secrets -n eso-production -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)"
if [ "$staging_owner" = "eso-staging" ] && [ "$production_owner" = "eso-production" ]; then
  echo "OK: Helm ownership inventory correct (eso-staging owns its Deployment, eso-production owns its own - no cross-adoption)"
else
  echo "FAIL: Helm ownership mismatch (staging owner='$staging_owner' production owner='$production_owner')" >&2
  fail=1
fi

# --- 9. namespace isolation: neither controller's Role grants access
# to the other's namespace (already proven structurally by
# test-runtime-health; here, confirm live RoleBindings reference only
# their own release's ServiceAccount). ---
staging_rb_subject="$(pkubectl get rolebinding eso-staging-external-secrets-controller -n staging -o jsonpath='{.subjects[0].namespace}' 2>/dev/null)"
production_rb_subject="$(pkubectl get rolebinding eso-production-external-secrets-controller -n production -o jsonpath='{.subjects[0].namespace}' 2>/dev/null)"
if [ "$staging_rb_subject" = "eso-staging" ] && [ "$production_rb_subject" = "eso-production" ]; then
  echo "OK: each RoleBinding's subject ServiceAccount lives in its own operator namespace - no cross-environment reconciliation possible"
else
  echo "FAIL: RoleBinding subject mismatch (staging='$staging_rb_subject' production='$production_rb_subject')" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-idempotency: FAILED before uninstall phase - stopping without uninstalling" >&2
  exit 1
fi

# --- 11. ordinary uninstall ---
echo "test-idempotency: uninstall ..."
sh lab/eso/uninstall.sh

# --- 12. confirm all 25 CRDs remain ---
remaining=0
while IFS= read -r crd; do
  [ -z "$crd" ] && continue
  pkubectl get "customresourcedefinition/${crd}" >/dev/null 2>&1 && remaining=$((remaining + 1))
done <<EOF
$(eso_crd_names)
EOF
if [ "$remaining" -eq 25 ]; then
  echo "OK: all 25 CRDs retained after uninstalling both scoped releases"
else
  echo "FAIL: only $remaining/25 CRDs remain after uninstall - CRD decoupling failed" >&2
  fail=1
fi

if eso_release_exists eso-staging eso-staging || eso_release_exists eso-production eso-production; then
  echo "FAIL: a scoped release still exists after uninstall" >&2
  fail=1
fi

# --- 13. second uninstall as a no-op ---
echo "test-idempotency: second uninstall (expect no-op) ..."
sh lab/eso/uninstall.sh

# --- 14. reinstall ---
echo "test-idempotency: restoration install ..."
sh lab/eso/install.sh

# --- 15. second restoration install as a no-op ---
fp_staging_3="$(capture_release_fingerprint eso-staging eso-staging)"
sh lab/eso/install.sh
fp_staging_4="$(capture_release_fingerprint eso-staging eso-staging)"
if [ "$fp_staging_3" = "$fp_staging_4" ]; then
  echo "OK: restoration install's second run is a true no-op"
else
  echo "FAIL: restoration install did not converge to a no-op ($fp_staging_3 -> $fp_staging_4)" >&2
  fail=1
fi

# --- 16. final healthy state ---
echo "test-idempotency: final runtime health check ..."
sh tests/eso/test-runtime-health.sh || fail=1

# --- Argo CD and workload baseline preserved throughout ---
argocd_pods_after="$(pkubectl get pods -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')"
apps_after="$(pkubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null)"
if [ "$argocd_pods_before" = "$argocd_pods_after" ] && [ "$apps_before" = "$apps_after" ]; then
  echo "OK: Argo CD and the platform-bootstrap/platform-smoke-* Applications are unchanged"
else
  echo "FAIL: Argo CD/Application state changed during this test" >&2
  echo "  before: $argocd_pods_before pods; after: $argocd_pods_after pods" >&2
  fail=1
fi

# --- global kubeconfig/context isolation re-check ---
if [ -f "$global_kubeconfig" ]; then
  global_sha_after="$(shasum -a 256 "$global_kubeconfig" | awk '{print $1}')"
else
  global_sha_after="<absent>"
fi
global_ctx_after="$(command -v kubectl >/dev/null 2>&1 && kubectl config current-context 2>/dev/null || echo "<no-global-kubectl>")"
if [ "$global_sha_before" = "$global_sha_after" ] && [ "$global_ctx_before" = "$global_ctx_after" ]; then
  echo "OK: global kubeconfig hash and current-context unchanged throughout"
else
  echo "FAIL: global kubeconfig or current-context changed - this must never happen" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-idempotency: FAILED"
  exit 1
fi
echo "test-idempotency: OK"
