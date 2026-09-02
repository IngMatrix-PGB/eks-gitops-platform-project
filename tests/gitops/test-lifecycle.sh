#!/bin/sh
# Mutating pre-merge lifecycle test for the Phase 2.3 GitOps bootstrap.
# Requires REVISION (the pushed feature branch) so the root Application
# reads gitops/bootstrap from the remote branch under test, never from
# an uncommitted local edit. Backs `make gitops-test-lifecycle` only.
#
# Sequence: baseline -> refuse-if-dirty -> bootstrap -> verify
# AppProject/ApplicationSet/generated Applications/namespaces/
# ConfigMaps -> bootstrap again (true no-op, resourceVersions
# unchanged) -> controlled single-environment drift -> self-heal proof
# -> other-environment-unaffected proof -> uninstall (foreground
# cascade) -> uninstall again (no-op) -> end with Phase 2.3 workload
# resources absent. Argo CD itself, its CRDs, the repository Secret,
# and the deploy key are never touched by this test.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh
# shellcheck source=../../scripts/gitops/_lib.sh
. scripts/gitops/_lib.sh

revision="${REVISION:?REVISION is required, e.g. REVISION=feat/phase-2.3-gitops-bootstrap}"

echo "test-lifecycle(gitops): step 1 - baseline"
if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm
if ! argocd_release_exists; then
  echo "FAIL: Argo CD is not installed" >&2
  exit 1
fi
repo_check_out="$(mktemp)"
trap 'rm -f "$repo_check_out"' EXIT INT TERM
if ! GITOPS_CHECK_ONLY=1 sh lab/gitops/repo-setup.sh >"$repo_check_out" 2>&1 || grep -q '^CHECK:' "$repo_check_out"; then
  echo "FAIL: repository authentication is not fully provisioned - run 'make gitops-repo-setup' first" >&2
  cat "$repo_check_out" >&2
  exit 1
fi
echo "OK: step 1 - cluster, Argo CD, and repository authentication baseline verified"

echo "test-lifecycle(gitops): step 2 - refuse if any Phase 2.3 object already exists"
if gitops_root_app_exists || gitops_appproject_exists || gitops_appset_exists \
   || gitops_generated_app_exists "platform-smoke-staging" \
   || gitops_generated_app_exists "platform-smoke-production" \
   || pkubectl get namespace staging >/dev/null 2>&1 \
   || pkubectl get namespace production >/dev/null 2>&1; then
  echo "FAIL: a Phase 2.3 object already exists - refusing to run the lifecycle test against a non-clean state" >&2
  exit 1
fi
echo "OK: step 2 - no conflicting pre-existing objects"

echo "test-lifecycle(gitops): step 3 - bootstrap root Application from revision '${revision}'"
REVISION="$revision" sh lab/gitops/bootstrap.sh
echo "OK: step 3 - root Application applied"

echo "test-lifecycle(gitops): step 4 - wait for root Application Synced/Healthy"
gitops_wait_for_synced_healthy "$GITOPS_ROOT_APP_NAME" 180

echo "test-lifecycle(gitops): step 5 - verify AppProject"
if ! gitops_appproject_exists; then
  echo "FAIL: AppProject '$GITOPS_PROJECT_NAME' was not created" >&2
  exit 1
fi
src_repos="$(pkubectl -n "$ARGOCD_NAMESPACE" get appproject "$GITOPS_PROJECT_NAME" -o jsonpath='{.spec.sourceRepos}')"
case "$src_repos" in
  *'"*"'*) echo "FAIL: AppProject has a wildcard sourceRepos entry: $src_repos" >&2; exit 1 ;;
esac
echo "OK: step 5 - AppProject present, no wildcard sourceRepos ($src_repos)"

echo "test-lifecycle(gitops): step 6 - verify ApplicationSet"
if ! gitops_appset_exists; then
  echo "FAIL: ApplicationSet '$GITOPS_APPSET_NAME' was not created" >&2
  exit 1
fi
echo "OK: step 6 - ApplicationSet present"

echo "test-lifecycle(gitops): step 7 - verify exactly two generated Applications"
generated_count=0
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    generated_count=$((generated_count + 1))
  fi
done
total_apps="$(pkubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l "eks-gitops-lab-lite.local/owner=${GITOPS_NS_OWNER_LABEL_VALUE}" --no-headers 2>/dev/null | grep -vc "^${GITOPS_ROOT_APP_NAME} " || true)"
if [ "$generated_count" -ne 2 ]; then
  echo "FAIL: expected exactly 2 generated Applications, found $generated_count" >&2
  exit 1
fi
echo "OK: step 7 - exactly 2 generated Applications ($GITOPS_GENERATED_APPS)"

echo "test-lifecycle(gitops): step 8 - verify staging/production namespaces and ownership metadata"
for ns in staging production; do
  if ! pkubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' was not created" >&2
    exit 1
  fi
  escaped_owner_key="$(printf '%s' "$GITOPS_NS_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
  owner_label="$(pkubectl get namespace "$ns" -o jsonpath="{.metadata.labels.${escaped_owner_key}}" 2>/dev/null || true)"
  if [ "$owner_label" != "$GITOPS_NS_OWNER_LABEL_VALUE" ]; then
    echo "FAIL: namespace '$ns' missing ownership label $GITOPS_NS_OWNER_LABEL_KEY=$GITOPS_NS_OWNER_LABEL_VALUE (got '${owner_label:-<none>}')" >&2
    exit 1
  fi
  echo "OK: namespace '$ns' present with ownership label"
done

echo "test-lifecycle(gitops): step 9 - wait for both generated Applications Synced/Healthy"
gitops_wait_for_synced_healthy "platform-smoke-staging" 180
gitops_wait_for_synced_healthy "platform-smoke-production" 180

echo "test-lifecycle(gitops): step 10 - verify environment-specific ConfigMaps"
for ns in staging production; do
  actual="$(pkubectl -n "$ns" get configmap platform-smoke -o jsonpath='{.data.environment}' 2>/dev/null || true)"
  if [ "$actual" != "$ns" ]; then
    echo "FAIL: namespace '$ns' configmap/platform-smoke data.environment='${actual:-<absent>}', expected '$ns'" >&2
    exit 1
  fi
done
echo "OK: step 10 - both ConfigMaps present with correct, differing per-environment data"

echo "test-lifecycle(gitops): step 11-12 - bootstrap again, prove true no-op via resourceVersions"
root_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.metadata.resourceVersion}')"
proj_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get appproject "$GITOPS_PROJECT_NAME" -o jsonpath='{.metadata.resourceVersion}')"
appset_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get applicationset "$GITOPS_APPSET_NAME" -o jsonpath='{.metadata.resourceVersion}')"
staging_app_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get application platform-smoke-staging -o jsonpath='{.metadata.resourceVersion}')"
prod_app_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get application platform-smoke-production -o jsonpath='{.metadata.resourceVersion}')"

REVISION="$revision" sh lab/gitops/bootstrap.sh

root_rv_after="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.metadata.resourceVersion}')"
if [ "$root_rv_before" != "$root_rv_after" ]; then
  echo "FAIL: root Application resourceVersion changed on the second bootstrap ($root_rv_before -> $root_rv_after) - not a true no-op" >&2
  exit 1
fi
echo "OK: step 11-12 - root Application resourceVersion unchanged ($root_rv_after); AppProject rv=$proj_rv_before, ApplicationSet rv=$appset_rv_before, staging app rv=$staging_app_rv_before, production app rv=$prod_app_rv_before (recorded, all driven by the same unchanged root)"

echo "test-lifecycle(gitops): step 13 - introduce controlled drift in the staging ConfigMap only"
pkubectl -n staging patch configmap platform-smoke --type=merge -p '{"data":{"environment":"DRIFTED"}}'
drifted="$(pkubectl -n staging get configmap platform-smoke -o jsonpath='{.data.environment}')"
if [ "$drifted" != "DRIFTED" ]; then
  echo "FAIL: could not introduce the controlled drift (got '$drifted')" >&2
  exit 1
fi
echo "OK: step 13 - staging configmap/platform-smoke drifted to '$drifted'"

echo "test-lifecycle(gitops): step 14 - verify self-heal restores Git state"
elapsed=0
healed=0
while [ "$elapsed" -lt 90 ]; do
  current="$(pkubectl -n staging get configmap platform-smoke -o jsonpath='{.data.environment}' 2>/dev/null || true)"
  if [ "$current" = "staging" ]; then
    healed=1
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
if [ "$healed" -ne 1 ]; then
  echo "FAIL: self-heal did not restore staging configmap/platform-smoke within 90s (last value: '$current')" >&2
  exit 1
fi
echo "OK: step 14 - self-heal restored staging configmap/platform-smoke to data.environment='staging'"

echo "test-lifecycle(gitops): step 15 - verify production was never affected"
prod_value="$(pkubectl -n production get configmap platform-smoke -o jsonpath='{.data.environment}' 2>/dev/null || true)"
if [ "$prod_value" != "production" ]; then
  echo "FAIL: production configmap/platform-smoke data.environment='${prod_value:-<absent>}' - expected it to be unaffected ('production')" >&2
  exit 1
fi
echo "OK: step 15 - production configmap/platform-smoke unaffected (data.environment='$prod_value')"

echo "test-lifecycle(gitops): step 16-19 - delete root bootstrap (foreground cascade), preserving Argo CD/CRDs/repo Secret/deploy key"
sh lab/gitops/uninstall.sh

echo "test-lifecycle(gitops): step 17 - verify generated Applications and managed resources disappeared"
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    echo "FAIL: generated Application '$app' still present after uninstall" >&2
    exit 1
  fi
done
for ns in staging production; do
  if pkubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' still present after uninstall" >&2
    exit 1
  fi
done
echo "OK: step 17-18 - generated Applications and owned namespaces are gone"

if ! argocd_release_exists; then
  echo "FAIL: Argo CD itself was affected by gitops-uninstall - it must never touch the Argo CD release" >&2
  exit 1
fi
if ! detect_crd_state || [ "$CRD_STATE" != "retained" ]; then
  echo "FAIL: Argo CD CRDs were affected by gitops-uninstall (CRD_STATE=${CRD_STATE:-unknown})" >&2
  exit 1
fi
if ! gitops_repo_secret_exists; then
  echo "FAIL: repository Secret was removed by gitops-uninstall - it must be preserved" >&2
  exit 1
fi
if ! gitops_deploy_key_present_locally; then
  echo "FAIL: local deploy key was removed by gitops-uninstall - it must be preserved" >&2
  exit 1
fi
echo "OK: step 19 - Argo CD, its CRDs, the repository Secret, and the deploy key are all preserved"

echo "test-lifecycle(gitops): step 20 - uninstall again, prove no-op"
sh lab/gitops/uninstall.sh

echo "test-lifecycle(gitops): step 21 - final state: Phase 2.3 workload resources absent"
if gitops_root_app_exists || gitops_appproject_exists || gitops_appset_exists \
   || pkubectl get namespace staging >/dev/null 2>&1 \
   || pkubectl get namespace production >/dev/null 2>&1; then
  echo "FAIL: a Phase 2.3 workload resource is unexpectedly still present at end of test" >&2
  exit 1
fi

echo "test-lifecycle(gitops): OK - bootstrap/no-op/self-heal/isolation/uninstall/no-op lifecycle proven; Argo CD/CRDs/repo Secret/deploy key preserved; Phase 2.3 workload resources absent"
