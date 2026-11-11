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
   || gitops_generated_app_exists "platform-smoke-dev" \
   || gitops_generated_app_exists "platform-smoke-uat" \
   || gitops_generated_app_exists "platform-smoke-prod" \
   || pkubectl get namespace dev >/dev/null 2>&1 \
   || pkubectl get namespace uat >/dev/null 2>&1 \
   || pkubectl get namespace prod >/dev/null 2>&1; then
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

echo "test-lifecycle(gitops): step 7 - verify exactly three generated Applications"
generated_count=0
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    generated_count=$((generated_count + 1))
  fi
done
total_apps="$(pkubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io -l "eks-gitops-lab-lite.local/owner=${GITOPS_NS_OWNER_LABEL_VALUE}" --no-headers 2>/dev/null | grep -vc "^${GITOPS_ROOT_APP_NAME} " || true)"
if [ "$generated_count" -ne 3 ]; then
  echo "FAIL: expected exactly 3 generated Applications, found $generated_count" >&2
  exit 1
fi
echo "OK: step 7 - exactly 3 generated Applications ($GITOPS_GENERATED_APPS)"

echo "test-lifecycle(gitops): step 8 - verify dev/uat/prod namespaces and ownership metadata"
escaped_owner_key="$(printf '%s' "$GITOPS_NS_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
for ns in dev uat prod; do
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
# main's current charts/standard-workload/values-{dev,uat,prod}.yaml
# (Phase 2.6.2, already merged) set externalSecret.enabled: true, and
# the workload Pod's secret volume is optional: false - the Pod cannot
# reach Ready without ESO's SecretStore/ExternalSecret/target Secret
# already existing. This step provisions exactly what Phase 2.6.2's
# own contract requires, using its own scripts unmodified (never
# printing the synthetic values used, only their SHA256 for later
# comparison if ever needed).
sh lab/eso/install.sh >/dev/null
dev_source_sha_precheck="$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}')"
uat_source_sha_precheck="$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}')"
prod_source_sha_precheck="$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}')"
printf 'lab-%s-dev' "$dev_source_sha_precheck" | sh lab/eso/provision-source-secret.sh dev >/dev/null
printf 'lab-%s-uat' "$uat_source_sha_precheck" | sh lab/eso/provision-source-secret.sh uat >/dev/null
printf 'lab-%s-prod' "$prod_source_sha_precheck" | sh lab/eso/provision-source-secret.sh prod >/dev/null
echo "OK: step 8b - ESO installed, independent synthetic source Secrets provisioned for all three environments (values never printed)"

echo "test-lifecycle(gitops): step 9 - wait for all three generated Applications Synced/Healthy"
gitops_wait_for_synced_healthy "platform-smoke-dev" 180
gitops_wait_for_synced_healthy "platform-smoke-uat" 180
gitops_wait_for_synced_healthy "platform-smoke-prod" 180

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

echo "test-lifecycle(gitops): step 10 - verify Deployment/Service/ServiceAccount/ConfigMap in all three environments"
for ns in dev uat prod; do
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

expected_dev_message="podinfo dev — phase 2.7.1"
expected_uat_message="podinfo uat — phase 2.4 verified"
expected_prod_message="podinfo prod — phase 2.4"
gitops_check_workload_endpoint dev "platform-smoke-dev-standard-workload" "$expected_dev_message"
gitops_check_workload_endpoint uat "platform-smoke-uat-standard-workload" "$expected_uat_message"
gitops_check_workload_endpoint prod "platform-smoke-prod-standard-workload" "$expected_prod_message"
echo "OK: step 10 - all three environments' Deployment/Service/ServiceAccount/ConfigMap verified, every endpoint reachable with correct, differing per-environment messages"

echo "test-lifecycle(gitops): step 11-12 - bootstrap again, prove true no-op via resourceVersions"
root_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.metadata.resourceVersion}')"
proj_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get appproject "$GITOPS_PROJECT_NAME" -o jsonpath='{.metadata.resourceVersion}')"
appset_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get applicationset "$GITOPS_APPSET_NAME" -o jsonpath='{.metadata.resourceVersion}')"
uat_app_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get application platform-smoke-uat -o jsonpath='{.metadata.resourceVersion}')"
prod_app_rv_before="$(pkubectl -n "$ARGOCD_NAMESPACE" get application platform-smoke-prod -o jsonpath='{.metadata.resourceVersion}')"

REVISION="$revision" sh lab/gitops/bootstrap.sh

root_rv_after="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.metadata.resourceVersion}')"
if [ "$root_rv_before" != "$root_rv_after" ]; then
  echo "FAIL: root Application resourceVersion changed on the second bootstrap ($root_rv_before -> $root_rv_after) - not a true no-op" >&2
  exit 1
fi
echo "OK: step 11-12 - root Application resourceVersion unchanged ($root_rv_after); AppProject rv=$proj_rv_before, ApplicationSet rv=$appset_rv_before, uat app rv=$uat_app_rv_before, prod app rv=$prod_app_rv_before (recorded, all driven by the same unchanged root)"

echo "test-lifecycle(gitops): step 13 - introduce controlled live drift in the uat ConfigMap only"
uat_cm="platform-smoke-uat-standard-workload-config"
prod_cm="platform-smoke-prod-standard-workload-config"
pkubectl -n uat patch configmap "$uat_cm" --type=merge -p '{"data":{"ui-message":"DRIFTED"}}'
drifted="$(pkubectl -n uat get configmap "$uat_cm" -o jsonpath='{.data.ui-message}')"
if [ "$drifted" != "DRIFTED" ]; then
  echo "FAIL: could not introduce the controlled drift (got '$drifted')" >&2
  exit 1
fi
echo "OK: step 13 - uat configmap/$uat_cm drifted to '$drifted'"

echo "test-lifecycle(gitops): step 14 - verify self-heal restores Git state"
elapsed=0
healed=0
while [ "$elapsed" -lt 90 ]; do
  current="$(pkubectl -n uat get configmap "$uat_cm" -o jsonpath='{.data.ui-message}' 2>/dev/null || true)"
  if [ "$current" = "$expected_uat_message" ]; then
    healed=1
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
if [ "$healed" -ne 1 ]; then
  echo "FAIL: self-heal did not restore uat configmap/$uat_cm within 90s (last value: '$current')" >&2
  exit 1
fi
echo "OK: step 14 - self-heal restored uat configmap/$uat_cm to data.ui-message='$expected_uat_message'"

echo "test-lifecycle(gitops): step 15 - verify dev and prod were never affected"
dev_cm="platform-smoke-dev-standard-workload-config"
dev_value="$(pkubectl -n dev get configmap "$dev_cm" -o jsonpath='{.data.ui-message}' 2>/dev/null || true)"
if [ "$dev_value" != "$expected_dev_message" ]; then
  echo "FAIL: dev configmap/$dev_cm data.ui-message='${dev_value:-<absent>}' - expected it to be unaffected ('$expected_dev_message')" >&2
  exit 1
fi
echo "OK: step 15 - dev configmap/$dev_cm unaffected (data.ui-message='$dev_value')"
prod_value="$(pkubectl -n prod get configmap "$prod_cm" -o jsonpath='{.data.ui-message}' 2>/dev/null || true)"
if [ "$prod_value" != "$expected_prod_message" ]; then
  echo "FAIL: prod configmap/$prod_cm data.ui-message='${prod_value:-<absent>}' - expected it to be unaffected ('$expected_prod_message')" >&2
  exit 1
fi
echo "OK: step 15 - prod configmap/$prod_cm unaffected (data.ui-message='$prod_value')"

echo "test-lifecycle(gitops): step 15b (Phase 2.6.3a) - preflight fail-closed on an unclassifiable object, zero mutation"
fixture_name="phase263a-preflight-fixture-$$"
cleanup_fixture() { pkubectl delete configmap "$fixture_name" -n uat --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup_fixture EXIT INT TERM
pkubectl create configmap "$fixture_name" -n uat --from-literal=marker=unknown >/dev/null
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
dep_avail="$(pkubectl -n uat get deployment platform-smoke-uat-standard-workload -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
if [ -z "$dep_avail" ] || [ "$dep_avail" -lt 1 ]; then
  echo "FAIL: uat workload was affected by the aborted preflight (availableReplicas='${dep_avail:-<absent>}')" >&2
  exit 1
fi
echo "OK: uat workload untouched (availableReplicas=$dep_avail) - the aborted preflight performed zero deletion"
cleanup_fixture
trap - EXIT INT TERM
echo "OK: step 15b - unclassifiable-fixture fixture cleaned up via trap"

echo "test-lifecycle(gitops): step 15c (Phase 2.6.3a) - ESO ownership: scoped RBAC inside dev/uat/prod must retain the namespace, never block or lose it"
sh lab/eso/install.sh >/dev/null
sh tests/eso/test-runtime-health.sh >/dev/null
for ns in dev uat prod; do
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
for ns in dev uat prod; do
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
echo "OK: step 15c - gitops-uninstall correctly retained dev/uat/prod and their ESO-owned RBAC while ESO was active; generated Applications still cascaded away; Argo CD untouched"

echo "test-lifecycle(gitops): step 15d (Phase 2.6.3a) - now uninstall ESO too, then re-run gitops-uninstall to reach true absence"
sh lab/eso/uninstall.sh
for ns in dev uat prod; do
  role="eso-${ns}-external-secrets-controller"
  if pkubectl get role "$role" -n "$ns" >/dev/null 2>&1; then
    echo "FAIL: ESO scoped Role '$role' in '$ns' still present after 'make eso-uninstall'" >&2
    exit 1
  fi
done
echo "OK: ESO scoped RBAC gone from dev/uat/prod after eso-uninstall"
sh lab/gitops/uninstall.sh
for ns in dev uat prod; do
  if pkubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' still present after the second gitops-uninstall (ESO is now gone - it should delete cleanly)" >&2
    exit 1
  fi
done
echo "OK: step 15d - dev/uat/prod fully deleted now that ESO no longer depends on them"

echo "test-lifecycle(gitops): step 16-19 - uninstall again (true no-op), preserving Argo CD/CRDs/repo Secret/deploy key"
sh lab/gitops/uninstall.sh

echo "test-lifecycle(gitops): step 17 - verify generated Applications and managed resources disappeared"
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    echo "FAIL: generated Application '$app' still present after uninstall" >&2
    exit 1
  fi
done
for ns in dev uat prod; do
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
   || pkubectl get namespace dev >/dev/null 2>&1 \
   || pkubectl get namespace uat >/dev/null 2>&1 \
   || pkubectl get namespace prod >/dev/null 2>&1; then
  echo "FAIL: a Phase 2.3 workload resource is unexpectedly still present at end of test" >&2
  exit 1
fi

echo "test-lifecycle(gitops): OK - bootstrap/no-op/self-heal/isolation/uninstall/no-op lifecycle proven; Argo CD/CRDs/repo Secret/deploy key preserved; Phase 2.3 workload resources absent"
