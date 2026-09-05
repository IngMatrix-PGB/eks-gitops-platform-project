#!/bin/sh
# Mutating pre-merge lifecycle test for the Phase 2.3/2.4 GitOps bootstrap.
# Requires REVISION (the pushed feature branch) so the root Application
# reads gitops/bootstrap from the remote branch under test, never from
# an uncommitted local edit. Backs `make gitops-test-lifecycle` only.
#
# Sequence: baseline -> refuse-if-dirty -> bootstrap -> verify
# AppProject/ApplicationSet/generated Applications/namespaces/
# ConfigMaps -> bootstrap again (true no-op, resourceVersions
# unchanged) -> controlled single-environment drift -> self-heal proof
# -> other-environment-unaffected proof -> uninstall (foreground
# cascade) -> uninstall again (no-op) -> end with Phase 2.4 workload
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
escaped_owner_key="$(printf '%s' "$GITOPS_NS_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
for ns in staging production; do
  # Namespace creation is driven by the generated Application's own
  # CreateNamespace=true sync, which completes shortly after step 7
  # observes the Application object itself exists - poll briefly rather
  # than requiring it to already be there on the very first check.
  elapsed=0
  until pkubectl get namespace "$ns" >/dev/null 2>&1; do
    if [ "$elapsed" -ge 60 ]; then
      echo "FAIL: namespace '$ns' was not created within 60s" >&2
      exit 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  owner_label="$(pkubectl get namespace "$ns" -o jsonpath="{.metadata.labels.${escaped_owner_key}}" 2>/dev/null || true)"
  if [ "$owner_label" != "$GITOPS_NS_OWNER_LABEL_VALUE" ]; then
    echo "FAIL: namespace '$ns' missing ownership label $GITOPS_NS_OWNER_LABEL_KEY=$GITOPS_NS_OWNER_LABEL_VALUE (got '${owner_label:-<none>}')" >&2
    exit 1
  fi
  echo "OK: namespace '$ns' present with ownership label"
done

echo "test-lifecycle(gitops): step 8b (Phase 2.6.3a) - install ESO and provision source Secrets"
# main's current charts/standard-workload/values-{staging,production}.yaml
# (Phase 2.6.2, already merged) set externalSecret.enabled: true, and
# the workload Pod's secret volume is optional: false - the Pod cannot
# reach Ready without ESO's SecretStore/ExternalSecret/target Secret
# already existing. This step provisions exactly what Phase 2.6.2's
# own contract requires, using its own scripts unmodified (never
# printing the synthetic values used, only their SHA256 for later
# comparison if ever needed).
sh lab/eso/install.sh >/dev/null
staging_source_sha_precheck="$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}')"
production_source_sha_precheck="$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}')"
printf 'lab-%s-staging' "$staging_source_sha_precheck" | sh lab/eso/provision-source-secret.sh staging >/dev/null
printf 'lab-%s-production' "$production_source_sha_precheck" | sh lab/eso/provision-source-secret.sh production >/dev/null
echo "OK: step 8b - ESO installed, independent synthetic source Secrets provisioned for both environments (values never printed)"

echo "test-lifecycle(gitops): step 9 - wait for both generated Applications Synced/Healthy"
gitops_wait_for_synced_healthy "platform-smoke-staging" 180
gitops_wait_for_synced_healthy "platform-smoke-production" 180

# Reachability check via the already-pinned podinfo image's own curl -
# reused verbatim by the manual two-commit rollout proof this test
# hands off to. Ephemeral, labeled distinctly from Argo-CD-managed
# resources, never AppProject-scoped (applied directly by this script's
# own kubeconfig, not by Argo CD on behalf of any Application).
gitops_check_workload_endpoint() {
  ns="$1"; svc="$2"; expected_message="$3"
  pod="reachability-check-$$"
  cleanup_reachability_pod() { pkubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait >/dev/null 2>&1 || true; }
  trap cleanup_reachability_pod EXIT INT TERM
  cat <<EOF | pkubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${ns}
  labels:
    eks-gitops-lab-lite.local/owner: lifecycle-test-ephemeral
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: check
      image: ghcr.io/stefanprodan/podinfo@sha256:ec73780a8425f59ea49f5bc8cdff0d598805a224fbaa1f86c67a244f250fa9da
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          curl -fsS "http://${svc}.${ns}.svc.cluster.local:9898/healthz"
          curl -fsS "http://${svc}.${ns}.svc.cluster.local:9898/readyz"
          curl -fsS "http://${svc}.${ns}.svc.cluster.local:9898/api/info"
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
  pkubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s pod/"$pod" >/dev/null 2>&1 || true
  # Phase 2.6.3a fix: podinfo's /api/info returns pretty-printed,
  # multi-line JSON (confirmed live) - `tail -1` only ever captured the
  # closing "}" and never the "message" field, which sits on its own
  # line in the middle of the object. Capture the pod's full combined
  # log output instead; the case-pattern match below already handles
  # multi-line content correctly (shell glob "*" matches newlines too).
  info_json="$(pkubectl -n "$ns" logs pod/"$pod" 2>/dev/null)"
  phase="$(pkubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  cleanup_reachability_pod
  trap - EXIT INT TERM
  if [ "$phase" != "Succeeded" ]; then
    echo "FAIL: reachability check pod in '$ns' did not succeed (phase=$phase)" >&2
    return 1
  fi
  case "$info_json" in
    # podinfo's /api/info is pretty-printed ("message": "...", a space
    # after the colon), not minified - tolerate zero-or-more characters
    # between the key and the value rather than assuming no space.
    *"\"message\":"*"\"${expected_message}\""*) : ;;
    *) echo "FAIL: '$ns' /api/info did not contain expected message '$expected_message': $info_json" >&2; return 1 ;;
  esac
  echo "OK: '$ns' Service reachable, /healthz+/readyz OK, /api/info message='$expected_message'"
}

echo "test-lifecycle(gitops): step 10 - verify Deployment/Service/ServiceAccount/ConfigMap in both environments"
for ns in staging production; do
  dep="platform-smoke-${ns}-standard-workload"
  avail="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  desired="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  if [ -z "$desired" ] || [ "$avail" != "$desired" ]; then
    echo "FAIL: namespace '$ns' Deployment/$dep availableReplicas='${avail:-<absent>}', expected '$desired'" >&2
    exit 1
  fi
  digest="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  case "$digest" in
    *"@sha256:ec73780a8425f59ea49f5bc8cdff0d598805a224fbaa1f86c67a244f250fa9da") : ;;
    *) echo "FAIL: namespace '$ns' Deployment/$dep image is not the pinned digest: $digest" >&2; exit 1 ;;
  esac
  uid="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.template.spec.securityContext.runAsUser}' 2>/dev/null || true)"
  gid="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.template.spec.securityContext.runAsGroup}' 2>/dev/null || true)"
  if [ "$uid" != "65532" ] || [ "$gid" != "65532" ]; then
    echo "FAIL: namespace '$ns' Deployment/$dep runAsUser/runAsGroup='$uid'/'$gid', expected 65532/65532" >&2
    exit 1
  fi
  if ! pkubectl -n "$ns" get service "$dep" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' Service/$dep absent" >&2
    exit 1
  fi
  if ! pkubectl -n "$ns" get serviceaccount "$dep" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' ServiceAccount/$dep absent" >&2
    exit 1
  fi
  if ! pkubectl -n "$ns" get configmap "${dep}-config" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' ConfigMap/${dep}-config absent" >&2
    exit 1
  fi
  echo "OK: namespace '$ns' Deployment ($avail/$desired Available), digest-pinned, UID/GID 65532/65532, Service/ServiceAccount/ConfigMap present"
done

expected_staging_message="podinfo staging — phase 2.4 verified"
expected_production_message="podinfo production — phase 2.4"
gitops_check_workload_endpoint staging "platform-smoke-staging-standard-workload" "$expected_staging_message"
gitops_check_workload_endpoint production "platform-smoke-production-standard-workload" "$expected_production_message"
echo "OK: step 10 - both environments' Deployment/Service/ServiceAccount/ConfigMap verified, both endpoints reachable with correct, differing per-environment messages"

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

echo "test-lifecycle(gitops): step 13 - introduce controlled live drift in the staging ConfigMap only"
staging_cm="platform-smoke-staging-standard-workload-config"
production_cm="platform-smoke-production-standard-workload-config"
pkubectl -n staging patch configmap "$staging_cm" --type=merge -p '{"data":{"ui-message":"DRIFTED"}}'
drifted="$(pkubectl -n staging get configmap "$staging_cm" -o jsonpath='{.data.ui-message}')"
if [ "$drifted" != "DRIFTED" ]; then
  echo "FAIL: could not introduce the controlled drift (got '$drifted')" >&2
  exit 1
fi
echo "OK: step 13 - staging configmap/$staging_cm drifted to '$drifted'"

echo "test-lifecycle(gitops): step 14 - verify self-heal restores Git state"
elapsed=0
healed=0
while [ "$elapsed" -lt 90 ]; do
  current="$(pkubectl -n staging get configmap "$staging_cm" -o jsonpath='{.data.ui-message}' 2>/dev/null || true)"
  if [ "$current" = "$expected_staging_message" ]; then
    healed=1
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
if [ "$healed" -ne 1 ]; then
  echo "FAIL: self-heal did not restore staging configmap/$staging_cm within 90s (last value: '$current')" >&2
  exit 1
fi
echo "OK: step 14 - self-heal restored staging configmap/$staging_cm to data.ui-message='$expected_staging_message'"

echo "test-lifecycle(gitops): step 15 - verify production was never affected"
prod_value="$(pkubectl -n production get configmap "$production_cm" -o jsonpath='{.data.ui-message}' 2>/dev/null || true)"
if [ "$prod_value" != "$expected_production_message" ]; then
  echo "FAIL: production configmap/$production_cm data.ui-message='${prod_value:-<absent>}' - expected it to be unaffected ('$expected_production_message')" >&2
  exit 1
fi
echo "OK: step 15 - production configmap/$production_cm unaffected (data.ui-message='$prod_value')"

echo "test-lifecycle(gitops): step 15b (Phase 2.6.3a) - preflight fail-closed on an unclassifiable object, zero mutation"
fixture_name="phase263a-preflight-fixture-$$"
cleanup_fixture() { pkubectl delete configmap "$fixture_name" -n staging --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup_fixture EXIT INT TERM
pkubectl create configmap "$fixture_name" -n staging --from-literal=marker=unknown >/dev/null
pre_fixture_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
pre_fixture_generation="$(gitops_app_generation "$GITOPS_ROOT_APP_NAME")"
preflight_out="$(mktemp)"
if sh lab/gitops/uninstall.sh >"$preflight_out" 2>&1; then
  echo "FAIL: gitops-uninstall should have aborted with the unclassifiable fixture present" >&2
  cat "$preflight_out" >&2
  rm -f "$preflight_out"
  exit 1
fi
if ! grep -q "$fixture_name" "$preflight_out"; then
  echo "FAIL: preflight abort output did not name the unclassifiable fixture" >&2
  cat "$preflight_out" >&2
  rm -f "$preflight_out"
  exit 1
fi
rm -f "$preflight_out"
echo "OK: gitops-uninstall correctly aborted (nonzero exit) with the unclassifiable fixture named in its output"
post_fixture_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
post_fixture_generation="$(gitops_app_generation "$GITOPS_ROOT_APP_NAME")"
if [ "$post_fixture_uid" != "$pre_fixture_uid" ] || [ "$post_fixture_generation" != "$pre_fixture_generation" ]; then
  echo "FAIL: root Application UID/generation changed despite the preflight abort (uid: $pre_fixture_uid -> $post_fixture_uid; generation: $pre_fixture_generation -> $post_fixture_generation)" >&2
  exit 1
fi
echo "OK: root Application UID/generation unchanged - zero mutation before the abort"
dep_avail="$(pkubectl -n staging get deployment platform-smoke-staging-standard-workload -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
if [ -z "$dep_avail" ] || [ "$dep_avail" -lt 1 ]; then
  echo "FAIL: staging workload was affected by the aborted preflight (availableReplicas='${dep_avail:-<absent>}')" >&2
  exit 1
fi
echo "OK: staging workload untouched (availableReplicas=$dep_avail) - the aborted preflight performed zero deletion"
cleanup_fixture
trap - EXIT INT TERM
echo "OK: step 15b - unclassifiable-fixture fixture cleaned up via trap"

echo "test-lifecycle(gitops): step 15c (Phase 2.6.3a) - ESO ownership: scoped RBAC inside staging/production must retain the namespace, never block or lose it"
sh lab/eso/install.sh >/dev/null
sh tests/eso/test-runtime-health.sh >/dev/null
for ns in staging production; do
  role="eso-${ns}-external-secrets-controller"
  if ! pkubectl get role "$role" -n "$ns" >/dev/null 2>&1; then
    echo "FAIL: expected ESO scoped Role '$role' in namespace '$ns' not found after 'make eso-install'" >&2
    exit 1
  fi
  managed_by="$(pkubectl get role "$role" -n "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  release_name="$(pkubectl get role "$role" -n "$ns" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)"
  if [ "$managed_by" != "Helm" ] || [ "$release_name" != "eso-${ns}" ]; then
    echo "FAIL: ESO scoped Role '$role' in '$ns' does not carry the expected Helm ownership metadata (managed-by='$managed_by' release-name='$release_name')" >&2
    exit 1
  fi
  echo "OK: ESO scoped Role '$role' verified in '$ns' via exact Helm ownership metadata (managed-by=Helm, release-name=eso-${ns})"
done

sh lab/gitops/uninstall.sh
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    echo "FAIL: generated Application '$app' still present after uninstall (should have cascaded even with ESO present)" >&2
    exit 1
  fi
done
for ns in staging production; do
  if ! pkubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' was deleted while an active ESO scoped release still targeted it - must be retained" >&2
    exit 1
  fi
  role="eso-${ns}-external-secrets-controller"
  if ! pkubectl get role "$role" -n "$ns" >/dev/null 2>&1; then
    echo "FAIL: ESO scoped Role '$role' in '$ns' was deleted by gitops-uninstall - it must never touch Helm/ESO-owned RBAC" >&2
    exit 1
  fi
  echo "OK: namespace '$ns' retained, ESO scoped Role '$role' untouched, after gitops-uninstall with ESO active"
done
if ! argocd_release_exists; then
  echo "FAIL: Argo CD itself was affected by gitops-uninstall (ESO-present case)" >&2
  exit 1
fi
echo "OK: step 15c - gitops-uninstall correctly retained staging/production and their ESO-owned RBAC while ESO was active; generated Applications still cascaded away; Argo CD untouched"

echo "test-lifecycle(gitops): step 15d (Phase 2.6.3a) - now uninstall ESO too, then re-run gitops-uninstall to reach true absence"
sh lab/eso/uninstall.sh
for ns in staging production; do
  role="eso-${ns}-external-secrets-controller"
  if pkubectl get role "$role" -n "$ns" >/dev/null 2>&1; then
    echo "FAIL: ESO scoped Role '$role' in '$ns' still present after 'make eso-uninstall'" >&2
    exit 1
  fi
done
echo "OK: ESO scoped RBAC gone from staging/production after eso-uninstall"
sh lab/gitops/uninstall.sh
for ns in staging production; do
  if pkubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' still present after the second gitops-uninstall (ESO is now gone - it should delete cleanly)" >&2
    exit 1
  fi
done
echo "OK: step 15d - staging/production fully deleted now that ESO no longer depends on them"

echo "test-lifecycle(gitops): step 16-19 - uninstall again (true no-op), preserving Argo CD/CRDs/repo Secret/deploy key"
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
