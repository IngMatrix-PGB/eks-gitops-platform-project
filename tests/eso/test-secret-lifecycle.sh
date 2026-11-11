#!/bin/sh
# Mutating, bounded runtime lifecycle test for the Phase 2.6.2 secret
# reconciliation contract, per .local/evidence/phase-2.6-external-
# secrets-plan.md §14 (21 steps). Uses only project-local tooling
# (.tools/bin/*, .local/kubeconfig) against the real eks-gitops-lab-lite
# cluster. Never prints a decoded secret value - every comparison below
# is a SHA256 hash, a resourceVersion, a UID, or a status/condition
# string. Backs `make eso-test-secret-lifecycle` only.
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
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh
# shellcheck source=../../scripts/gitops/_lib.sh
. scripts/gitops/_lib.sh

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity - run 'make lab-create' first" >&2
  exit 1
fi
require_helm
require_eso_chart

fail=0
current_branch="$(git rev-parse --abbrev-ref HEAD)"

# --- 1. baseline (hash/context only, never content). Phase 2.6.3b:
# uses global_kubeconfig_fingerprint (scripts/lab/_lib.sh), immune to
# any KUBECONFIG this shell may have inherited, instead of the
# previous ad-hoc inline check - which was found live to give
# inconsistent readings across separate invocations specifically
# because it trusted an inherited KUBECONFIG rather than always
# passing the global path explicitly. ---
if ! assert_kubeconfig_paths_distinct; then
  exit 1
fi
read -r global_sha_before global_ctx_before <<EOF
$(global_kubeconfig_fingerprint)
EOF
kind_clusters_before="$(.tools/bin/kind get clusters 2>/dev/null)"
echo "OK: captured baseline (kubeconfig sha256 ${global_sha_before}, context ${global_ctx_before}, kind clusters: ${kind_clusters_before})"

# --- 2. ESO install (idempotent - no-op if already installed) ---
echo "test-secret-lifecycle: ensuring ESO is installed ..."
sh lab/eso/install.sh

# --- 3. every scoped release's Deployments Available ---
sh tests/eso/test-runtime-health.sh

# --- 4. CRD counts by group ---
all_crds="$(pkubectl get crd -o name)"
es_count="$(printf '%s\n' "$all_crds" | grep '\.external-secrets\.io$' | grep -vc '\.generators\.external-secrets\.io$' || true)"
gen_count="$(printf '%s\n' "$all_crds" | grep -c '\.generators\.external-secrets\.io$' || true)"
if [ "$es_count" -eq 6 ] && [ "$gen_count" -eq 19 ]; then
  echo "OK: CRD group counts correct (6 external-secrets.io, 19 generators.external-secrets.io)"
else
  echo "FAIL: unexpected CRD group counts (external-secrets.io=$es_count, generators.external-secrets.io=$gen_count)" >&2
  fail=1
fi
for crd in secretstores.external-secrets.io externalsecrets.external-secrets.io; do
  ver="$(pkubectl get crd "$crd" -o jsonpath='{.spec.versions[0].name}')"
  [ "$ver" = "v1" ] && echo "OK: $crd API version is v1" || { echo "FAIL: $crd API version is '$ver', expected v1" >&2; fail=1; }
done

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before provisioning any secret material" >&2
  exit 1
fi

# --- 5. independent, synthetic, lab-only source secrets for all three
# environments - random, never printed, generated locally, exclusive to
# this lab. Never the same value. This test is itself re-runnable, and
# Phase 2.6.3b's default (no-flag) path is now a true no-op when the
# Secret already exists (by design) - so a re-run must use --rotate to
# actually force in a fresh, this-run-only value; --rotate requires
# the Secret to pre-exist, so the first-ever run (absent) still uses
# the plain create path. ---
echo "test-secret-lifecycle: provisioning independent source secrets ..."
uat_source_value="lab-$(date +%s)-$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-16)-uat"
prod_source_value="lab-$(date +%s)-$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-16)-prod"
dev_source_value="lab-$(date +%s)-$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-16)-dev"
uat_provision_flag=""
pkubectl get secret local-backend-uat -n eso-source-uat >/dev/null 2>&1 && uat_provision_flag="--rotate"
prod_provision_flag=""
pkubectl get secret local-backend-prod -n eso-source-prod >/dev/null 2>&1 && prod_provision_flag="--rotate"
dev_provision_flag=""
pkubectl get secret local-backend-dev -n eso-source-dev >/dev/null 2>&1 && dev_provision_flag="--rotate"
printf '%s' "$uat_source_value" | sh lab/eso/provision-source-secret.sh uat $uat_provision_flag
printf '%s' "$prod_source_value" | sh lab/eso/provision-source-secret.sh prod $prod_provision_flag
printf '%s' "$dev_source_value" | sh lab/eso/provision-source-secret.sh dev $dev_provision_flag
uat_source_sha="$(printf '%s' "$uat_source_value" | shasum -a 256 | awk '{print $1}')"
prod_source_sha="$(printf '%s' "$prod_source_value" | shasum -a 256 | awk '{print $1}')"
dev_source_sha="$(printf '%s' "$dev_source_value" | shasum -a 256 | awk '{print $1}')"
if [ "$uat_source_sha" = "$prod_source_sha" ] || [ "$dev_source_sha" = "$uat_source_sha" ] || [ "$dev_source_sha" = "$prod_source_sha" ]; then
  echo "FAIL: two source values collided (identical hash) - test fixture is broken" >&2
  fail=1
else
  echo "OK: dev, uat, and prod source secrets provisioned with pairwise-distinct values (dev sha256 $dev_source_sha, uat sha256 $uat_source_sha, prod sha256 $prod_source_sha)"
fi

# --- 6. reconcile the chart's now-enabled SecretStore/ExternalSecret
# for all three environments, from this test branch.
#
# `make gitops-bootstrap` (lab/gitops/bootstrap.sh) is deliberately
# fail-closed on a revision switch: it treats "root Application already
# exists with a different targetRevision" as indistinguishable from
# accidental drift, so it refuses to reconcile automatically. This
# project's own tests/gitops/test-lifecycle.sh works around that by
# tearing the bootstrap down first (lab/gitops/uninstall.sh) - but that
# script's namespace-inventory check was written before Phase 2.6.1
# existed, and does not account for the ESO scoped-RBAC Role/
# RoleBinding objects (scopedRBAC: true) that now also live in the
# uat/prod namespaces. Verified empirically on this exact
# cluster: calling it here left `uat`/`prod` non-empty
# (ESO's Roles/RoleBindings), which made the script refuse to delete
# the namespace, and by then its earlier step had already cascaded the
# root Application's deletion through to the generated Applications'
# managed resources - deleting the running platform-smoke-uat/
# platform-smoke-prod Deployments outright. That was recovered
# by an immediate `make gitops-bootstrap REVISION=main`, and is flagged
# separately as a pre-existing, out-of-scope gap in
# lab/gitops/uninstall.sh (not one of this phase's 14 authorized
# paths) - not fixed here.
#
# The safe alternative, used from here on: a plain `kubectl apply` of
# the same rendered manifest lab/gitops/bootstrap.sh would apply
# updates the existing Application object IN PLACE (a server-side
# apply/patch, never a delete), so it never touches the
# resources-finalizer cascade at all. Argo CD then reconciles
# AppProject/ApplicationSet in place from the new revision; the
# ApplicationSet's generator produces the same two Application names
# as before, so they are updated in place too - this is what actually
# preserves "the two generated Applications" and "existing workloads"
# throughout, and still proves self-heal picks up the new
# SecretStore/ExternalSecret templates. ---
echo "test-secret-lifecycle: reconciling GitOps from branch '$current_branch' (in-place apply, never a delete) ..."
require_helm
if ! argocd_release_exists; then
  echo "FAIL: Argo CD is not installed" >&2
  exit 1
fi
if ! gitops_remote_revision_exists "$current_branch"; then
  echo "FAIL: remote revision '$current_branch' does not exist on $GITOPS_REPO_URL - push it first" >&2
  exit 1
fi
apply_file="$(gitops_render_root_app_for_revision "$current_branch")"
pkubectl apply -f "$apply_file"
echo "OK: root Application updated in place to revision '$current_branch' (no delete, no cascade)"
pkubectl annotate application platform-bootstrap -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
gitops_wait_for_synced_healthy platform-bootstrap 240
for app in $GITOPS_GENERATED_APPS; do
  gitops_wait_for_synced_healthy "$app" 240
done

# Phase 3.2.1: the poll-until-timeout loop itself now lives in
# wait_until (scripts/lab/_lib.sh) - this function only defines the
# predicate and the timeout/interval, preserving its exact prior
# behavior (same jsonpath, same default 90s timeout, same 3s interval,
# silent on both outcomes, same 0/1 return).
_wait_for_condition_predicate() {
  _wfc_status="$(pkubectl get "$_wfc_resource" -n "$_wfc_ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$_wfc_status" = "True" ]
}
wait_for_condition() {
  # $1=resource $2=namespace $3=timeout-seconds
  _wfc_resource="$1"; _wfc_ns="$2"; timeout="${3:-90}"
  wait_until _wait_for_condition_predicate "$timeout" 3
}

# --- 7. every SecretStore Ready ---
echo "test-secret-lifecycle: waiting for every SecretStore to be Ready ..."
if wait_for_condition secretstore/dev-kubernetes-backend dev 90; then
  echo "OK: dev SecretStore Ready"
else
  echo "FAIL: dev SecretStore did not become Ready in time" >&2
  fail=1
fi
if wait_for_condition secretstore/uat-kubernetes-backend uat 90; then
  echo "OK: uat SecretStore Ready"
else
  echo "FAIL: uat SecretStore did not become Ready in time" >&2
  fail=1
fi
if wait_for_condition secretstore/prod-kubernetes-backend prod 90; then
  echo "OK: prod SecretStore Ready"
else
  echo "FAIL: prod SecretStore did not become Ready in time" >&2
  fail=1
fi

# --- 8. every ExternalSecret Ready ---
echo "test-secret-lifecycle: waiting for every ExternalSecret to be Ready ..."
if wait_for_condition externalsecret/platform-smoke-dev-standard-workload-secret dev 90; then
  echo "OK: dev ExternalSecret Ready"
else
  echo "FAIL: dev ExternalSecret did not become Ready in time" >&2
  fail=1
fi
if wait_for_condition externalsecret/platform-smoke-uat-standard-workload-secret uat 90; then
  echo "OK: uat ExternalSecret Ready"
else
  echo "FAIL: uat ExternalSecret did not become Ready in time" >&2
  fail=1
fi
if wait_for_condition externalsecret/platform-smoke-prod-standard-workload-secret prod 90; then
  echo "OK: prod ExternalSecret Ready"
else
  echo "FAIL: prod ExternalSecret did not become Ready in time" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before target-Secret verification" >&2
  exit 1
fi

# --- 9. target Secrets created by ESO ---
uat_target="platform-smoke-uat-standard-workload-secret"
prod_target="platform-smoke-prod-standard-workload-secret"
dev_target="platform-smoke-dev-standard-workload-secret"
pkubectl get secret "$dev_target" -n dev >/dev/null 2>&1 && echo "OK: dev target Secret exists" || { echo "FAIL: dev target Secret missing" >&2; fail=1; }
pkubectl get secret "$uat_target" -n uat >/dev/null 2>&1 && echo "OK: uat target Secret exists" || { echo "FAIL: uat target Secret missing" >&2; fail=1; }
pkubectl get secret "$prod_target" -n prod >/dev/null 2>&1 && echo "OK: prod target Secret exists" || { echo "FAIL: prod target Secret missing" >&2; fail=1; }

# --- ownership: the target Secret is owned by the ExternalSecret ---
uat_owner_kind="$(pkubectl get secret "$uat_target" -n uat -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
prod_owner_kind="$(pkubectl get secret "$prod_target" -n prod -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
dev_owner_kind="$(pkubectl get secret "$dev_target" -n dev -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
if [ "$uat_owner_kind" = "ExternalSecret" ] && [ "$prod_owner_kind" = "ExternalSecret" ] && [ "$dev_owner_kind" = "ExternalSecret" ]; then
  echo "OK: every target Secret is owned by its ExternalSecret (creationPolicy: Owner)"
else
  echo "FAIL: unexpected target Secret ownership (dev='$dev_owner_kind' uat='$uat_owner_kind' prod='$prod_owner_kind')" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before workload verification" >&2
  exit 1
fi

# --- workloads Available (Pods were blocked in ContainerCreating until
# the target Secret existed, since optional: false) ---
echo "test-secret-lifecycle: waiting for workload rollout ..."
pkubectl rollout status deployment/platform-smoke-uat-standard-workload -n uat --timeout=120s >/dev/null
pkubectl rollout status deployment/platform-smoke-prod-standard-workload -n prod --timeout=120s >/dev/null
pkubectl rollout status deployment/platform-smoke-dev-standard-workload -n dev --timeout=120s >/dev/null
echo "OK: dev, uat, and prod workload Deployments are Available"

# --- wait for the target Secret to reflect a specific expected hash,
# within refreshInterval (1m) plus a generous bound. This test is
# idempotent/re-runnable, and re-running rotates the source Secret (its
# own provisioning script is create-or-update) - so on any run after
# the first, the target Secret can still hold the PREVIOUS run's value
# for up to one refreshInterval tick after step 5 provisions a new one.
# A one-shot read here would be a false failure, not a real defect. ---
# Phase 3.2.1: predicate extracted for wait_until (scripts/lab/_lib.sh);
# same hardcoded 90s/3s, same echoed value on both outcomes.
_wait_for_target_hash_predicate() {
  _wfth_current="$(pkubectl get secret "$_wfth_target_secret" -n "$_wfth_ns" -o jsonpath='{.data.message}' 2>/dev/null | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  [ "$_wfth_current" = "$_wfth_expected_sha" ]
}
wait_for_target_hash() {
  _wfth_ns="$1"; _wfth_target_secret="$2"; _wfth_expected_sha="$3"
  if wait_until _wait_for_target_hash_predicate 90 3; then
    echo "$_wfth_current"
    return 0
  fi
  echo "${_wfth_current:-<unavailable>}"
  return 1
}

# --- wait for the mounted file to reflect a specific expected hash.
# Retries for up to 90s: a rollout can be immediately superseded by a
# follow-up Argo CD self-heal sync (observed empirically right after a
# revision switch - a second rollout replaced the Pod moments after
# the first was confirmed Available), so a single one-shot `exec` can
# transiently land on a Pod that is already terminating, and the
# kubelet's own projected-volume sync loop needs its own bounded time
# on top of that. Never prints the decoded content, only its hash. ---
# Phase 3.2.1: predicate extracted for wait_until (scripts/lab/_lib.sh);
# same hardcoded 90s/3s, same stale-value-persists quirk on a later
# iteration with no Running pod (current/pod_name only reassigned
# inside the `-n "$pod_name"` branch, exactly as before), same echoed
# value+pod-name on both outcomes.
_wait_for_mounted_hash_predicate() {
  _wfmh_pod_name="$(pkubectl get pod -n "$_wfmh_pod_label_ns" -l "app.kubernetes.io/instance=platform-smoke-${_wfmh_ns}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$_wfmh_pod_name" ]; then
    _wfmh_current="$(pkubectl exec -n "$_wfmh_pod_label_ns" "$_wfmh_pod_name" -- sha256sum /etc/secret/message 2>/dev/null | awk '{print $1}')"
    [ "$_wfmh_current" = "$_wfmh_expected_sha" ]
  else
    return 1
  fi
}
wait_for_mounted_hash() {
  _wfmh_ns="$1"; _wfmh_pod_label_ns="$2"; _wfmh_expected_sha="$3"
  if wait_until _wait_for_mounted_hash_predicate 90 3; then
    echo "${_wfmh_current} ${_wfmh_pod_name}"
    return 0
  fi
  echo "${_wfmh_current:-<unavailable>} ${_wfmh_pod_name:-<none>}"
  return 1
}

echo "test-secret-lifecycle: waiting for target Secrets and mounted files to reflect the provisioned source values ..."
uat_target_sha_1="$(wait_for_target_hash uat "$uat_target" "$uat_source_sha")" \
  && echo "OK: uat target Secret matches the provisioned source (sha256 $uat_target_sha_1)" \
  || { echo "FAIL: uat target Secret did not converge to the provisioned source within 90s (got $uat_target_sha_1, expected $uat_source_sha)" >&2; fail=1; }
prod_target_sha_1="$(wait_for_target_hash prod "$prod_target" "$prod_source_sha")" \
  && echo "OK: prod target Secret matches the provisioned source (sha256 $prod_target_sha_1)" \
  || { echo "FAIL: prod target Secret did not converge to the provisioned source within 90s (got $prod_target_sha_1, expected $prod_source_sha)" >&2; fail=1; }
dev_target_sha_1="$(wait_for_target_hash dev "$dev_target" "$dev_source_sha")" \
  && echo "OK: dev target Secret matches the provisioned source (sha256 $dev_target_sha_1)" \
  || { echo "FAIL: dev target Secret did not converge to the provisioned source within 90s (got $dev_target_sha_1, expected $dev_source_sha)" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before mounted-file verification" >&2
  exit 1
fi

read -r uat_mounted_sha_1 uat_pod_1 <<EOF
$(wait_for_mounted_hash uat uat "$uat_source_sha")
EOF
if [ "$uat_mounted_sha_1" = "$uat_source_sha" ]; then
  echo "OK: uat source/target/mounted-file hashes all match ($uat_mounted_sha_1)"
else
  echo "FAIL: uat mounted-file hash did not converge (source=$uat_source_sha target=$uat_target_sha_1 mounted=$uat_mounted_sha_1)" >&2
  fail=1
fi
read -r prod_mounted_sha_1 prod_pod_1 <<EOF
$(wait_for_mounted_hash prod prod "$prod_source_sha")
EOF
if [ "$prod_mounted_sha_1" = "$prod_source_sha" ]; then
  echo "OK: prod source/target/mounted-file hashes all match ($prod_mounted_sha_1)"
else
  echo "FAIL: prod mounted-file hash did not converge (source=$prod_source_sha target=$prod_target_sha_1 mounted=$prod_mounted_sha_1)" >&2
  fail=1
fi

read -r dev_mounted_sha_1 dev_pod_1 <<EOF
$(wait_for_mounted_hash dev dev "$dev_source_sha")
EOF
if [ "$dev_mounted_sha_1" = "$dev_source_sha" ]; then
  echo "OK: dev source/target/mounted-file hashes all match ($dev_mounted_sha_1)"
else
  echo "FAIL: dev mounted-file hash did not converge (source=$dev_source_sha target=$dev_target_sha_1 mounted=$dev_mounted_sha_1)" >&2
  fail=1
fi

# --- 10. dev, uat, and prod hashes pairwise differ ---
if [ "$uat_target_sha_1" != "$prod_target_sha_1" ] && [ "$dev_target_sha_1" != "$uat_target_sha_1" ] && [ "$dev_target_sha_1" != "$prod_target_sha_1" ]; then
  echo "OK: dev, uat, and prod hashes pairwise differ - real per-environment isolation, not a copy-paste value"
else
  echo "FAIL: two environments' target Secret hashes are identical" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before rotation testing" >&2
  exit 1
fi

# --- capture prod's and dev's resourceVersion/Pod UID before rotating
# uat only, to prove isolation afterward ---
prod_target_rv_before="$(pkubectl get secret "$prod_target" -n prod -o jsonpath='{.metadata.resourceVersion}')"
prod_pod_uid_before="$(pkubectl get pod "$prod_pod_1" -n prod -o jsonpath='{.metadata.uid}')"
dev_target_rv_before="$(pkubectl get secret "$dev_target" -n dev -o jsonpath='{.metadata.resourceVersion}')"
dev_pod_uid_before="$(pkubectl get pod "$dev_pod_1" -n dev -o jsonpath='{.metadata.uid}')"

# --- 13. rotate uat's source secret only. Phase 2.6.3b: the
# script's default (no-flag) path is now a true no-op on an existing
# Secret - --rotate is required to actually change its value. ---
echo "test-secret-lifecycle: rotating uat's source secret ..."
uat_source_value_2="lab-$(date +%s)-$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-16)-rotated"
printf '%s' "$uat_source_value_2" | sh lab/eso/provision-source-secret.sh uat --rotate
uat_source_sha_2="$(printf '%s' "$uat_source_value_2" | shasum -a 256 | awk '{print $1}')"
if [ "$uat_source_sha_2" = "$uat_source_sha" ]; then
  echo "FAIL: rotated uat value hashes to the same value as before - test fixture is broken" >&2
  fail=1
fi

# --- 12/14/15. propagation to target Secret and mounted file, within
# refreshInterval (1m) plus a generous kubelet-sync bound; prod and
# dev must remain fully unchanged throughout. ---
echo "test-secret-lifecycle: waiting for rotation to propagate (refreshInterval + kubelet sync, bounded) ..."
propagated=0
elapsed=0
while [ "$elapsed" -lt 180 ]; do
  current_target_sha="$(pkubectl get secret "$uat_target" -n uat -o jsonpath='{.data.message}' 2>/dev/null | base64 -d | shasum -a 256 | awk '{print $1}')"
  if [ "$current_target_sha" = "$uat_source_sha_2" ]; then
    propagated=1
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
if [ "$propagated" -eq 1 ]; then
  echo "OK: uat target Secret propagated the rotated value within ${elapsed}s (sha256 $current_target_sha)"
else
  echo "FAIL: uat target Secret did not propagate the rotated value within 180s" >&2
  fail=1
fi

# mounted file: give the kubelet's own sync loop additional bounded time
mounted_propagated=0
elapsed=0
while [ "$elapsed" -lt 180 ]; do
  current_mounted_sha="$(pkubectl exec -n uat "$uat_pod_1" -- sha256sum /etc/secret/message 2>/dev/null | awk '{print $1}')"
  if [ "$current_mounted_sha" = "$uat_source_sha_2" ]; then
    mounted_propagated=1
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
if [ "$mounted_propagated" -eq 1 ]; then
  echo "OK: uat mounted file propagated the rotated value within ${elapsed}s, no Pod restart required (sha256 $current_mounted_sha)"
else
  echo "FAIL: uat mounted file did not propagate the rotated value within 180s" >&2
  fail=1
fi

# --- 16. prod and dev remain fully unchanged ---
prod_target_rv_after="$(pkubectl get secret "$prod_target" -n prod -o jsonpath='{.metadata.resourceVersion}')"
prod_pod_uid_after="$(pkubectl get pod "$prod_pod_1" -n prod -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
prod_target_sha_after="$(pkubectl get secret "$prod_target" -n prod -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
if [ "$prod_target_rv_before" = "$prod_target_rv_after" ] \
  && [ "$prod_pod_uid_before" = "$prod_pod_uid_after" ] \
  && [ "$prod_target_sha_after" = "$prod_target_sha_1" ]; then
  echo "OK: prod target Secret resourceVersion, Pod UID, and hash are all unchanged (isolation proof)"
else
  echo "FAIL: prod changed during uat's rotation (rv: $prod_target_rv_before -> $prod_target_rv_after; uid: $prod_pod_uid_before -> $prod_pod_uid_after; hash: $prod_target_sha_1 -> $prod_target_sha_after)" >&2
  fail=1
fi
dev_target_rv_after="$(pkubectl get secret "$dev_target" -n dev -o jsonpath='{.metadata.resourceVersion}')"
dev_pod_uid_after="$(pkubectl get pod "$dev_pod_1" -n dev -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
dev_target_sha_after="$(pkubectl get secret "$dev_target" -n dev -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
if [ "$dev_target_rv_before" = "$dev_target_rv_after" ] \
  && [ "$dev_pod_uid_before" = "$dev_pod_uid_after" ] \
  && [ "$dev_target_sha_after" = "$dev_target_sha_1" ]; then
  echo "OK: dev target Secret resourceVersion, Pod UID, and hash are all unchanged (isolation proof)"
else
  echo "FAIL: dev changed during uat's rotation (rv: $dev_target_rv_before -> $dev_target_rv_after; uid: $dev_pod_uid_before -> $dev_pod_uid_after; hash: $dev_target_sha_1 -> $dev_target_sha_after)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before target-Secret deletion/recreation test" >&2
  exit 1
fi

# --- 17 (per this task's numbering)/14 (per the plan): delete the
# uat target Secret manually and confirm ESO recreates it with the
# same (rotated) value, within refreshInterval. ---
echo "test-secret-lifecycle: deleting the uat target Secret to prove ESO recreates it ..."
uat_target_uid_before_delete="$(pkubectl get secret "$uat_target" -n uat -o jsonpath='{.metadata.uid}')"
pkubectl delete secret "$uat_target" -n uat
recreated=0
elapsed=0
while [ "$elapsed" -lt 90 ]; do
  if pkubectl get secret "$uat_target" -n uat >/dev/null 2>&1; then
    recreated_sha="$(pkubectl get secret "$uat_target" -n uat -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
    if [ "$recreated_sha" = "$uat_source_sha_2" ]; then
      recreated=1
      break
    fi
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
if [ "$recreated" -eq 1 ]; then
  uat_target_uid_after_delete="$(pkubectl get secret "$uat_target" -n uat -o jsonpath='{.metadata.uid}')"
  echo "OK: ESO recreated the deleted target Secret with the same value within ${elapsed}s (new UID, as expected for a fresh object: before=$uat_target_uid_before_delete after=$uat_target_uid_after_delete)"
else
  echo "FAIL: ESO did not recreate the deleted target Secret within 90s" >&2
  fail=1
fi

# --- 18/15 (per the plan's numbering): re-run bootstrap and confirm a
# true no-op on the chart-rendered GitOps resources. ---
echo "test-secret-lifecycle: re-running gitops-bootstrap, expecting a true no-op ..."
uat_ss_rv_1="$(pkubectl get secretstore uat-kubernetes-backend -n uat -o jsonpath='{.metadata.resourceVersion}')"
uat_es_rv_1="$(pkubectl get externalsecret platform-smoke-uat-standard-workload-secret -n uat -o jsonpath='{.metadata.resourceVersion}')"
make gitops-bootstrap REVISION="$current_branch"
uat_ss_rv_2="$(pkubectl get secretstore uat-kubernetes-backend -n uat -o jsonpath='{.metadata.resourceVersion}')"
uat_es_rv_2="$(pkubectl get externalsecret platform-smoke-uat-standard-workload-secret -n uat -o jsonpath='{.metadata.resourceVersion}')"
if [ "$uat_ss_rv_1" = "$uat_ss_rv_2" ] && [ "$uat_es_rv_1" = "$uat_es_rv_2" ]; then
  echo "OK: re-running gitops-bootstrap is a true no-op (SecretStore/ExternalSecret resourceVersion unchanged)"
else
  echo "FAIL: gitops-bootstrap re-run was not a no-op (SecretStore rv $uat_ss_rv_1 -> $uat_ss_rv_2; ExternalSecret rv $uat_es_rv_1 -> $uat_es_rv_2)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before ESO uninstall/retention testing" >&2
  exit 1
fi

# --- capture Argo CD / standard-workload baseline before touching ESO ---
argocd_pods_before="$(pkubectl get pods -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')"
apps_before="$(pkubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null)"

# --- 16 (this task's numbering)/19: uninstall the scoped ESO releases
# and confirm the target Secrets survive (deletionPolicy: Retain +
# they were never owned by the Helm release in the first place). ---
echo "test-secret-lifecycle: uninstalling ESO (scoped releases only) ..."
sh lab/eso/uninstall.sh

pkubectl get secret "$uat_target" -n uat >/dev/null 2>&1 && echo "OK: uat target Secret survives ESO uninstall" || { echo "FAIL: uat target Secret was deleted by ESO uninstall" >&2; fail=1; }
pkubectl get secret "$prod_target" -n prod >/dev/null 2>&1 && echo "OK: prod target Secret survives ESO uninstall" || { echo "FAIL: prod target Secret was deleted by ESO uninstall" >&2; fail=1; }
pkubectl get secret "$dev_target" -n dev >/dev/null 2>&1 && echo "OK: dev target Secret survives ESO uninstall" || { echo "FAIL: dev target Secret was deleted by ESO uninstall" >&2; fail=1; }

# --- 18: Argo CD and the standard-workload baseline unaffected ---
argocd_pods_after="$(pkubectl get pods -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')"
apps_after="$(pkubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null)"
if [ "$argocd_pods_before" = "$argocd_pods_after" ] && [ "$apps_before" = "$apps_after" ]; then
  echo "OK: Argo CD and platform-bootstrap/platform-smoke-* Applications unaffected by ESO uninstall"
else
  echo "FAIL: Argo CD/Application state changed during ESO uninstall" >&2
  fail=1
fi

# --- 19: second uninstall is a no-op ---
echo "test-secret-lifecycle: second ESO uninstall (expect no-op) ..."
sh lab/eso/uninstall.sh

# --- 20/21: restore the pre-test baseline. This PR is not merged, so
# main does not carry this feature yet - "the final state defined by
# the plan" here means returning the cluster to exactly the state it
# was in before this test ran (main-tracked bootstrap, Phase 2.4/2.6.1
# workloads, no SecretStore/ExternalSecret), not a state that assumes
# an unmerged change. ESO itself is reinstalled (its 25 CRDs were never
# removed - only its scoped releases were, in the block above). As
# in step 6, this uses an in-place `kubectl apply` back to main rather
# than lab/gitops/uninstall.sh + gitops-bootstrap, for the same reason:
# that script's namespace-inventory check does not account for ESO's
# scoped-RBAC objects now living in dev/uat/prod and would again
# refuse to clean up, after already cascading a delete through the
# generated Applications' managed resources. The source Secrets
# provisioned in step 5/13 (eso-source-dev/-uat/-prod)
# are deliberately NOT deleted here: they are outside Git/Helm/Argo CD
# entirely, and once this PR merges, main's own
# values-{dev,uat,prod}.yaml will need them to already
# exist for the ExternalSecrets to reconcile immediately. ---
#
# RESTORE_REVISION (default: main) names the revision to restore to.
# Phase 2.7.1: a change that renames the environments themselves (as
# 2.7.1 does) cannot restore to a pre-merge main whose environments
# have different names - pass RESTORE_REVISION=<this branch> for that
# pre-merge run only, and record it as such in the PR's evidence.
restore_revision="${RESTORE_REVISION:-main}"
echo "test-secret-lifecycle: restoring persistent state (ESO reinstall + GitOps back to '$restore_revision', in-place apply) ..."
sh lab/eso/install.sh
main_apply_file="$(gitops_render_root_app_for_revision "$restore_revision")"
pkubectl apply -f "$main_apply_file"
echo "OK: root Application updated in place back to revision '$restore_revision' (no delete, no cascade)"

# Observed empirically on this exact cluster: a self-heal-triggered
# automated sync operation that was queued/retrying WHILE the
# Application was still pointed at the feature branch can remain stuck
# retrying that stale manifest snapshot even after the live spec has
# already switched back to main (it fails every retry on the same
# now-disallowed SecretStore, and each failed attempt still partially
# re-applies the still-allowed pieces - the ServiceAccount and the
# Deployment's secret volume - so the Application oscillates instead of
# converging). Clearing any in-flight/queued operation here forces the
# next automated sync to be computed fresh against the CURRENT desired
# state (main, no SecretStore), which converges cleanly. Never disables
# self-heal - it re-triggers immediately on its own, correctly this
# time.
for app in $GITOPS_GENERATED_APPS; do
  pkubectl patch application "$app" -n argocd --type=merge -p '{"operation":null}' >/dev/null 2>&1 || true
done
pkubectl annotate application platform-bootstrap -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
gitops_wait_for_synced_healthy platform-bootstrap 240 || fail=1
for app in $GITOPS_GENERATED_APPS; do
  gitops_wait_for_synced_healthy "$app" 240 || fail=1
done

# gitops_wait_for_synced_healthy can observe a stale "Synced" read taken
# moments before a hard-refresh recomputes the diff (observed
# empirically: the aggregate status briefly still says Synced/Healthy
# while a leftover ServiceAccount from the branch and the Deployment's
# reverted spec are still mid-reconciliation) - self-heal completes
# this on its own within a few minutes, but a stable, resource-level
# check is required here rather than trusting the first "Synced" read.
# Phase 3.2.1: predicate extracted for wait_until (scripts/lab/_lib.sh);
# same default 180s timeout, same 5s interval (distinct from the other
# three predicates' 3s - preserved via the explicit argument), same
# OK/FAIL messages on stdout/stderr.
_wait_for_no_out_of_sync_resources_predicate() {
  _wfoosr_remaining="$(pkubectl get application "$_wfoosr_app" -n argocd -o jsonpath='{.status.resources[?(@.status=="OutOfSync")].kind}' 2>/dev/null)"
  [ -z "$_wfoosr_remaining" ]
}
wait_for_no_out_of_sync_resources() {
  _wfoosr_app="$1"; timeout="${2:-180}"
  if wait_until _wait_for_no_out_of_sync_resources_predicate "$timeout" 5; then
    echo "OK: Application/$_wfoosr_app has zero OutOfSync resources"
    return 0
  fi
  echo "FAIL: Application/$_wfoosr_app still has OutOfSync resource(s) after ${timeout}s: $_wfoosr_remaining" >&2
  return 1
}
for app in platform-bootstrap $GITOPS_GENERATED_APPS; do
  wait_for_no_out_of_sync_resources "$app" 180 || fail=1
done

# Phase 2.6.3b fix: this block used to delete SecretStore/
# ExternalSecret/the target Secret and wait for their ABSENCE, on the
# assumption that "main" did not yet have the feature (Phase 2.6.2 was
# still unmerged at the time this was first written). main has since
# merged Phase 2.6.2 - its own AppProject still whitelists
# SecretStore/ExternalSecret, and both environments' values files still
# set externalSecret.enabled: true, so main WANTS these objects to
# exist and be Ready. The old delete-and-wait-for-absence logic was
# racing against self-heal recreating exactly what it had just deleted
# (main renders them), which could never converge - reproduced live,
# consistently, at this exact step. The correct restore-to-main
# condition is the opposite: SecretStore/ExternalSecret present and
# Ready, and the target Secret present - stable across 3 consecutive
# checks (45s), not just once, to distinguish "converged" from
# "transiently clean, about to change again," which a single read
# cannot tell apart. ---
stable_checks=0
elapsed=0
while [ "$elapsed" -lt 420 ] && [ "$stable_checks" -lt 3 ]; do
  clean=1
  ss_uat="$(pkubectl get secretstore uat-kubernetes-backend -n uat -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ss_uat" = "True" ] || clean=0
  ss_dev="$(pkubectl get secretstore dev-kubernetes-backend -n dev -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ss_dev" = "True" ] || clean=0
  es_dev="$(pkubectl get externalsecret "$dev_target" -n dev -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$es_dev" = "True" ] || clean=0
  pkubectl get secret "$dev_target" -n dev >/dev/null 2>&1 || clean=0
  ss_prod="$(pkubectl get secretstore prod-kubernetes-backend -n prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ss_prod" = "True" ] || clean=0
  es_uat="$(pkubectl get externalsecret "$uat_target" -n uat -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$es_uat" = "True" ] || clean=0
  es_prod="$(pkubectl get externalsecret "$prod_target" -n prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$es_prod" = "True" ] || clean=0
  pkubectl get secret "$uat_target" -n uat >/dev/null 2>&1 || clean=0
  pkubectl get secret "$prod_target" -n prod >/dev/null 2>&1 || clean=0
  for app in $GITOPS_GENERATED_APPS; do
    status="$(pkubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
    [ "$status" = "Synced/Healthy" ] || clean=0
  done
  if [ "$clean" -eq 1 ]; then
    stable_checks=$((stable_checks + 1))
  else
    stable_checks=0
  fi
  sleep 15
  elapsed=$((elapsed + 15))
done
if [ "$stable_checks" -ge 3 ]; then
  echo "OK: SecretStore/ExternalSecret/target Secret present and Ready after restoring to '$restore_revision' (it renders them), stable across 3 consecutive checks"
else
  echo "FAIL: cluster state did not stabilize (SecretStore/ExternalSecret Ready, target Secrets present, every Application Synced/Healthy) within 420s after restoring to '$restore_revision'" >&2
  fail=1
fi
pkubectl rollout status deployment/platform-smoke-uat-standard-workload -n uat --timeout=120s >/dev/null
pkubectl rollout status deployment/platform-smoke-prod-standard-workload -n prod --timeout=120s >/dev/null
pkubectl rollout status deployment/platform-smoke-dev-standard-workload -n dev --timeout=120s >/dev/null
echo "OK: dev, uat, and prod workload Deployments are Available again on '$restore_revision'"

# --- final health check (Phase 2.6.1 ESO bootstrap baseline) ---
sh tests/eso/test-runtime-health.sh || fail=1

# --- 21: global kubeconfig/context/cluster-list isolation re-check
# (same explicit-path helper as the baseline capture - never the
# ambient KUBECONFIG). ---
read -r global_sha_after global_ctx_after <<EOF
$(global_kubeconfig_fingerprint)
EOF
kind_clusters_after="$(.tools/bin/kind get clusters 2>/dev/null)"
if [ "$global_sha_before" = "$global_sha_after" ] && [ "$global_ctx_before" = "$global_ctx_after" ] && [ "$kind_clusters_before" = "$kind_clusters_after" ]; then
  echo "OK: global kubeconfig hash, current-context, and kind cluster list are unchanged throughout"
else
  echo "FAIL: global kubeconfig/context/cluster-list changed - this must never happen" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED"
  exit 1
fi
echo "test-secret-lifecycle: OK"
