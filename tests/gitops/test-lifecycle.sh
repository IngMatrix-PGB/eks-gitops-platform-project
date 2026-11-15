#!/bin/sh
# Mutating pre-merge lifecycle test for the Phase 2.3/2.4 GitOps bootstrap.
# Requires REVISION (the pushed feature branch) so the root Application
# reads gitops/bootstrap from the remote branch under test, never from
# an uncommitted local edit. Backs `make gitops-test-lifecycle` only.
#
# Precondition: no GitOps object (root Application, AppProject,
# ApplicationSet, generated Applications) and no workload object inside
# dev/uat/prod. The namespaces themselves MAY exist: ESO's scoped
# releases (`make eso-install`) target them, and `make gitops-uninstall`
# deliberately RETAINS them while such a release is active. On a lab
# brought up per the runbook, run `make gitops-uninstall` first.
# If ESO was already installed when the test started, the test leaves
# it installed and ends with dev/uat/prod retained (as it found them);
# otherwise it also uninstalls ESO and ends with them absent.
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
# shellcheck source=../../scripts/workload/_lib.sh
. scripts/workload/_lib.sh
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh
# shellcheck source=../../scripts/eso/_lib.sh
. scripts/eso/_lib.sh
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

echo "test-lifecycle(gitops): step 2 - refuse if any GitOps object or workload object already exists"
if gitops_root_app_exists || gitops_appproject_exists || gitops_appset_exists \
   || gitops_generated_app_exists "platform-smoke-dev" \
   || gitops_generated_app_exists "platform-smoke-uat" \
   || gitops_generated_app_exists "platform-smoke-prod"; then
  echo "FAIL: a GitOps object (root Application/AppProject/ApplicationSet/generated Application) already exists - run 'make gitops-uninstall' first; refusing to run the lifecycle test against a non-clean state" >&2
  exit 1
fi
# dev/uat/prod may legitimately exist (ESO scoped releases need them and
# gitops-uninstall retains them while one is active). What must NOT be
# there is any workload object: only Kubernetes built-ins and objects
# owned by an ESO scoped Helm release are accepted - the same
# classification gitops-uninstall's own preflight uses.
preexisting_namespaces=""
precheck_class="$(mktemp)"
for ns in dev uat prod; do
  if ! pkubectl get namespace "$ns" >/dev/null 2>&1; then
    continue
  fi
  preexisting_namespaces="${preexisting_namespaces} ${ns}"
  if ! gitops_classify_namespace "$ns" "platform-smoke-${ns}" "$precheck_class"; then
    rm -f "$precheck_class"
    echo "FAIL: could not classify the objects in pre-existing namespace '$ns' (discovery error)" >&2
    exit 1
  fi
  if grep -v -e '^kubernetes-builtin ' -e '^helm-eso-scoped ' "$precheck_class" >/dev/null; then
    echo "FAIL: pre-existing namespace '$ns' still holds workload object(s) - refusing to run against a non-clean state:" >&2
    grep -v -e '^kubernetes-builtin ' -e '^helm-eso-scoped ' "$precheck_class" | sed 's/^/  /' >&2
    rm -f "$precheck_class"
    exit 1
  fi
  echo "OK: pre-existing namespace '$ns' holds only Kubernetes built-ins and ESO-release-owned objects"
done
rm -f "$precheck_class"
eso_preinstalled=0
while IFS='|' read -r env_name eso_ns eso_release wc cc; do
  [ -z "$env_name" ] && continue
  if eso_release_exists "$eso_ns" "$eso_release"; then
    eso_preinstalled=1
  fi
done <<EOF
$(eso_environments)
EOF
echo "OK: step 2 - no GitOps or workload objects; pre-existing namespaces:${preexisting_namespaces:- none}; ESO installed before the test: $([ "$eso_preinstalled" -eq 1 ] && echo yes || echo no)"

echo "test-lifecycle(gitops): step 3 - bootstrap root Application from revision '${revision}'"
# R-13: the ESO CRDs must exist before the first sync (bootstrap.sh
# refuses otherwise). Idempotent; a no-op when they are already there.
sh lab/eso/install-crds.sh >/dev/null
REVISION="$revision" sh lab/gitops/bootstrap.sh
echo "OK: step 3 - ESO CRDs present, root Application applied"

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

# Reachability check from the pinned test client image (Phase 5.1c-1;
# before that, podinfo's own curl) - reused verbatim by the manual
# two-commit rollout proof this test hands off to. Ephemeral, labeled distinctly from Argo-CD-managed
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
      image: ${TEST_CLIENT_IMAGE}
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
# The Application CRD has no status subresource, so Argo CD's own
# status writes bump metadata.generation on their own (observed: 13 -> 14
# with nothing but the controller touching it). Zero mutation is proven
# by the UID, the .spec content hash, and the absence of a
# deletionTimestamp instead.
gitops_root_spec_sha() {
  pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec}' 2>/dev/null | shasum -a 256 | awk '{print $1}'
}
pre_fixture_spec_sha="$(gitops_root_spec_sha)"
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
post_fixture_spec_sha="$(gitops_root_spec_sha)"
post_fixture_deletion="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"
if [ "$post_fixture_uid" != "$pre_fixture_uid" ] || [ "$post_fixture_spec_sha" != "$pre_fixture_spec_sha" ] || [ -n "$post_fixture_deletion" ]; then
  echo "FAIL: root Application changed despite the preflight abort (uid: $pre_fixture_uid -> $post_fixture_uid; spec sha256: $pre_fixture_spec_sha -> $post_fixture_spec_sha; deletionTimestamp='${post_fixture_deletion}')" >&2
  exit 1
fi
echo "OK: root Application UID and spec unchanged, no deletionTimestamp - zero mutation before the abort"
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

# Final-state assertion shared by every uninstall below: GitOps objects
# gone, Argo CD/CRDs/repository Secret/deploy key preserved, and
# dev/uat/prod either absent (ESO removed) or retained holding only
# Kubernetes built-ins and ESO-release-owned objects (ESO kept).
gitops_assert_final_state() {
  gafs_label="$1"
  if gitops_root_app_exists || gitops_appproject_exists || gitops_appset_exists; then
    echo "FAIL: $gafs_label - root Application/AppProject/ApplicationSet still present" >&2
    exit 1
  fi
  for app in $GITOPS_GENERATED_APPS; do
    if gitops_generated_app_exists "$app"; then
      echo "FAIL: $gafs_label - generated Application '$app' still present" >&2
      exit 1
    fi
  done
  gafs_class="$(mktemp)"
  for ns in dev uat prod; do
    if [ "$eso_preinstalled" -eq 1 ]; then
      if ! pkubectl get namespace "$ns" >/dev/null 2>&1; then
        rm -f "$gafs_class"
        echo "FAIL: $gafs_label - namespace '$ns' was deleted while ESO (installed before the test) still targets it" >&2
        exit 1
      fi
      if ! gitops_classify_namespace "$ns" "platform-smoke-${ns}" "$gafs_class"; then
        rm -f "$gafs_class"
        echo "FAIL: $gafs_label - could not classify namespace '$ns' (discovery error)" >&2
        exit 1
      fi
      if grep -v -e '^kubernetes-builtin ' -e '^helm-eso-scoped ' "$gafs_class" >/dev/null; then
        echo "FAIL: $gafs_label - retained namespace '$ns' still holds workload object(s):" >&2
        grep -v -e '^kubernetes-builtin ' -e '^helm-eso-scoped ' "$gafs_class" | sed 's/^/  /' >&2
        rm -f "$gafs_class"
        exit 1
      fi
    elif pkubectl get namespace "$ns" >/dev/null 2>&1; then
      rm -f "$gafs_class"
      echo "FAIL: $gafs_label - namespace '$ns' still present (ESO is gone - it should have been deleted)" >&2
      exit 1
    fi
  done
  rm -f "$gafs_class"
  if ! argocd_release_exists; then
    echo "FAIL: $gafs_label - Argo CD itself was affected by gitops-uninstall" >&2
    exit 1
  fi
  if ! detect_crd_state || [ "$CRD_STATE" != "retained" ]; then
    echo "FAIL: $gafs_label - Argo CD CRDs were affected by gitops-uninstall (CRD_STATE=${CRD_STATE:-unknown})" >&2
    exit 1
  fi
  if ! gitops_repo_secret_exists; then
    echo "FAIL: $gafs_label - repository Secret was removed by gitops-uninstall - it must be preserved" >&2
    exit 1
  fi
  if ! gitops_deploy_key_present_locally; then
    echo "FAIL: $gafs_label - local deploy key was removed by gitops-uninstall - it must be preserved" >&2
    exit 1
  fi
}

if [ "$eso_preinstalled" -eq 1 ]; then
  echo "test-lifecycle(gitops): step 15d - SKIPPED: ESO was installed before the test, so it is left installed and dev/uat/prod stay retained (start from a lab without ESO to also cover the eso-uninstall -> full-absence path)"
  gitops_assert_final_state "step 15d"
  echo "OK: step 15d - state matches the precondition: no GitOps or workload objects, dev/uat/prod retained with only ESO-owned RBAC, ESO untouched"
else
  echo "test-lifecycle(gitops): step 15d (Phase 2.6.3a) - ESO was not installed before the test: uninstall it too, then re-run gitops-uninstall to reach true absence"
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
fi

echo "test-lifecycle(gitops): step 16-19 - uninstall again (true no-op), preserving Argo CD/CRDs/repo Secret/deploy key"
sh lab/gitops/uninstall.sh
gitops_assert_final_state "step 16-19"
echo "OK: step 16-19 - generated Applications gone, dev/uat/prod $([ "$eso_preinstalled" -eq 1 ] && echo "retained for ESO" || echo absent); Argo CD, its CRDs, the repository Secret, and the deploy key are all preserved"

echo "test-lifecycle(gitops): step 20 - uninstall again, prove no-op"
sh lab/gitops/uninstall.sh

echo "test-lifecycle(gitops): step 21 - final state"
gitops_assert_final_state "step 21"

echo "test-lifecycle(gitops): OK - bootstrap/no-op/self-heal/isolation/uninstall/no-op lifecycle proven; Argo CD/CRDs/repo Secret/deploy key preserved; GitOps and workload objects absent; dev/uat/prod $([ "$eso_preinstalled" -eq 1 ] && echo "retained for the ESO installed before the test" || echo absent)"
