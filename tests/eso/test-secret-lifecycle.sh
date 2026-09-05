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

# --- 1. baseline (hash/context only, never content) ---
global_kubeconfig="$HOME/.kube/config"
if [ -f "$global_kubeconfig" ]; then
  global_sha_before="$(shasum -a 256 "$global_kubeconfig" | awk '{print $1}')"
else
  global_sha_before="<absent>"
fi
global_ctx_before="$(command -v kubectl >/dev/null 2>&1 && kubectl config current-context 2>/dev/null || echo "<no-global-kubectl>")"
kind_clusters_before="$(.tools/bin/kind get clusters 2>/dev/null)"
echo "OK: captured baseline (kubeconfig sha256 ${global_sha_before}, context ${global_ctx_before}, kind clusters: ${kind_clusters_before})"

# --- 2. ESO install (idempotent - no-op if already installed) ---
echo "test-secret-lifecycle: ensuring ESO is installed ..."
sh lab/eso/install.sh

# --- 3. both scoped releases' Deployments Available ---
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

# --- 5. independent, synthetic, lab-only source secrets for both
# environments - random, never printed, generated locally, exclusive to
# this lab. Never the same value. ---
echo "test-secret-lifecycle: provisioning independent source secrets ..."
staging_source_value="lab-$(date +%s)-$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-16)-staging"
production_source_value="lab-$(date +%s)-$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-16)-production"
printf '%s' "$staging_source_value" | sh lab/eso/provision-source-secret.sh staging
printf '%s' "$production_source_value" | sh lab/eso/provision-source-secret.sh production
staging_source_sha="$(printf '%s' "$staging_source_value" | shasum -a 256 | awk '{print $1}')"
production_source_sha="$(printf '%s' "$production_source_value" | shasum -a 256 | awk '{print $1}')"
if [ "$staging_source_sha" = "$production_source_sha" ]; then
  echo "FAIL: staging and production source values collided (identical hash) - test fixture is broken" >&2
  fail=1
else
  echo "OK: staging and production source secrets provisioned with distinct values (staging sha256 $staging_source_sha, production sha256 $production_source_sha)"
fi

# --- 6. reconcile the chart's now-enabled SecretStore/ExternalSecret
# for both environments, from this test branch.
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
# staging/production namespaces. Verified empirically on this exact
# cluster: calling it here left `staging`/`production` non-empty
# (ESO's Roles/RoleBindings), which made the script refuse to delete
# the namespace, and by then its earlier step had already cascaded the
# root Application's deletion through to the generated Applications'
# managed resources - deleting the running platform-smoke-staging/
# platform-smoke-production Deployments outright. That was recovered
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

wait_for_condition() {
  # $1=resource $2=namespace $3=timeout-seconds
  resource="$1"; ns="$2"; timeout="${3:-90}"
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    status="$(pkubectl get "$resource" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$status" = "True" ] && return 0
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# --- 7. both SecretStores Ready ---
echo "test-secret-lifecycle: waiting for both SecretStores to be Ready ..."
if wait_for_condition secretstore/staging-kubernetes-backend staging 90; then
  echo "OK: staging SecretStore Ready"
else
  echo "FAIL: staging SecretStore did not become Ready in time" >&2
  fail=1
fi
if wait_for_condition secretstore/production-kubernetes-backend production 90; then
  echo "OK: production SecretStore Ready"
else
  echo "FAIL: production SecretStore did not become Ready in time" >&2
  fail=1
fi

# --- 8. both ExternalSecrets Ready ---
echo "test-secret-lifecycle: waiting for both ExternalSecrets to be Ready ..."
if wait_for_condition externalsecret/platform-smoke-staging-standard-workload-secret staging 90; then
  echo "OK: staging ExternalSecret Ready"
else
  echo "FAIL: staging ExternalSecret did not become Ready in time" >&2
  fail=1
fi
if wait_for_condition externalsecret/platform-smoke-production-standard-workload-secret production 90; then
  echo "OK: production ExternalSecret Ready"
else
  echo "FAIL: production ExternalSecret did not become Ready in time" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before target-Secret verification" >&2
  exit 1
fi

# --- 9. target Secrets created by ESO ---
staging_target="platform-smoke-staging-standard-workload-secret"
production_target="platform-smoke-production-standard-workload-secret"
pkubectl get secret "$staging_target" -n staging >/dev/null 2>&1 && echo "OK: staging target Secret exists" || { echo "FAIL: staging target Secret missing" >&2; fail=1; }
pkubectl get secret "$production_target" -n production >/dev/null 2>&1 && echo "OK: production target Secret exists" || { echo "FAIL: production target Secret missing" >&2; fail=1; }

# --- ownership: the target Secret is owned by the ExternalSecret ---
staging_owner_kind="$(pkubectl get secret "$staging_target" -n staging -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
production_owner_kind="$(pkubectl get secret "$production_target" -n production -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
if [ "$staging_owner_kind" = "ExternalSecret" ] && [ "$production_owner_kind" = "ExternalSecret" ]; then
  echo "OK: both target Secrets are owned by their ExternalSecret (creationPolicy: Owner)"
else
  echo "FAIL: unexpected target Secret ownership (staging='$staging_owner_kind' production='$production_owner_kind')" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before workload verification" >&2
  exit 1
fi

# --- workloads Available (Pods were blocked in ContainerCreating until
# the target Secret existed, since optional: false) ---
echo "test-secret-lifecycle: waiting for workload rollout ..."
pkubectl rollout status deployment/platform-smoke-staging-standard-workload -n staging --timeout=120s >/dev/null
pkubectl rollout status deployment/platform-smoke-production-standard-workload -n production --timeout=120s >/dev/null
echo "OK: staging and production workload Deployments are Available"

# --- wait for the target Secret to reflect a specific expected hash,
# within refreshInterval (1m) plus a generous bound. This test is
# idempotent/re-runnable, and re-running rotates the source Secret (its
# own provisioning script is create-or-update) - so on any run after
# the first, the target Secret can still hold the PREVIOUS run's value
# for up to one refreshInterval tick after step 5 provisions a new one.
# A one-shot read here would be a false failure, not a real defect. ---
wait_for_target_hash() {
  ns="$1"; target_secret="$2"; expected_sha="$3"
  elapsed=0
  while [ "$elapsed" -lt 90 ]; do
    current="$(pkubectl get secret "$target_secret" -n "$ns" -o jsonpath='{.data.message}' 2>/dev/null | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}')"
    [ "$current" = "$expected_sha" ] && { echo "$current"; return 0; }
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "${current:-<unavailable>}"
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
wait_for_mounted_hash() {
  ns="$1"; pod_label_ns="$2"; expected_sha="$3"
  elapsed=0
  while [ "$elapsed" -lt 90 ]; do
    pod_name="$(pkubectl get pod -n "$pod_label_ns" -l "app.kubernetes.io/instance=platform-smoke-${ns}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$pod_name" ]; then
      current="$(pkubectl exec -n "$pod_label_ns" "$pod_name" -- sha256sum /etc/secret/message 2>/dev/null | awk '{print $1}')"
      if [ "$current" = "$expected_sha" ]; then
        echo "${current} ${pod_name}"
        return 0
      fi
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "${current:-<unavailable>} ${pod_name:-<none>}"
  return 1
}

echo "test-secret-lifecycle: waiting for target Secrets and mounted files to reflect the provisioned source values ..."
staging_target_sha_1="$(wait_for_target_hash staging "$staging_target" "$staging_source_sha")" \
  && echo "OK: staging target Secret matches the provisioned source (sha256 $staging_target_sha_1)" \
  || { echo "FAIL: staging target Secret did not converge to the provisioned source within 90s (got $staging_target_sha_1, expected $staging_source_sha)" >&2; fail=1; }
production_target_sha_1="$(wait_for_target_hash production "$production_target" "$production_source_sha")" \
  && echo "OK: production target Secret matches the provisioned source (sha256 $production_target_sha_1)" \
  || { echo "FAIL: production target Secret did not converge to the provisioned source within 90s (got $production_target_sha_1, expected $production_source_sha)" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before mounted-file verification" >&2
  exit 1
fi

read -r staging_mounted_sha_1 staging_pod_1 <<EOF
$(wait_for_mounted_hash staging staging "$staging_source_sha")
EOF
if [ "$staging_mounted_sha_1" = "$staging_source_sha" ]; then
  echo "OK: staging source/target/mounted-file hashes all match ($staging_mounted_sha_1)"
else
  echo "FAIL: staging mounted-file hash did not converge (source=$staging_source_sha target=$staging_target_sha_1 mounted=$staging_mounted_sha_1)" >&2
  fail=1
fi
read -r production_mounted_sha_1 production_pod_1 <<EOF
$(wait_for_mounted_hash production production "$production_source_sha")
EOF
if [ "$production_mounted_sha_1" = "$production_source_sha" ]; then
  echo "OK: production source/target/mounted-file hashes all match ($production_mounted_sha_1)"
else
  echo "FAIL: production mounted-file hash did not converge (source=$production_source_sha target=$production_target_sha_1 mounted=$production_mounted_sha_1)" >&2
  fail=1
fi

# --- 10. staging and production hashes differ ---
if [ "$staging_target_sha_1" != "$production_target_sha_1" ]; then
  echo "OK: staging and production hashes differ - real per-environment isolation, not a copy-paste value"
else
  echo "FAIL: staging and production target Secret hashes are identical" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before rotation testing" >&2
  exit 1
fi

# --- capture production's resourceVersion/Pod UID before rotating
# staging only, to prove isolation afterward ---
production_target_rv_before="$(pkubectl get secret "$production_target" -n production -o jsonpath='{.metadata.resourceVersion}')"
production_pod_uid_before="$(pkubectl get pod "$production_pod_1" -n production -o jsonpath='{.metadata.uid}')"

# --- 13. rotate staging's source secret only ---
echo "test-secret-lifecycle: rotating staging's source secret ..."
staging_source_value_2="lab-$(date +%s)-$(head -c 16 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-16)-rotated"
printf '%s' "$staging_source_value_2" | sh lab/eso/provision-source-secret.sh staging
staging_source_sha_2="$(printf '%s' "$staging_source_value_2" | shasum -a 256 | awk '{print $1}')"
if [ "$staging_source_sha_2" = "$staging_source_sha" ]; then
  echo "FAIL: rotated staging value hashes to the same value as before - test fixture is broken" >&2
  fail=1
fi

# --- 12/14/15. propagation to target Secret and mounted file, within
# refreshInterval (1m) plus a generous kubelet-sync bound; production
# must remain fully unchanged throughout. ---
echo "test-secret-lifecycle: waiting for rotation to propagate (refreshInterval + kubelet sync, bounded) ..."
propagated=0
elapsed=0
while [ "$elapsed" -lt 180 ]; do
  current_target_sha="$(pkubectl get secret "$staging_target" -n staging -o jsonpath='{.data.message}' 2>/dev/null | base64 -d | shasum -a 256 | awk '{print $1}')"
  if [ "$current_target_sha" = "$staging_source_sha_2" ]; then
    propagated=1
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
if [ "$propagated" -eq 1 ]; then
  echo "OK: staging target Secret propagated the rotated value within ${elapsed}s (sha256 $current_target_sha)"
else
  echo "FAIL: staging target Secret did not propagate the rotated value within 180s" >&2
  fail=1
fi

# mounted file: give the kubelet's own sync loop additional bounded time
mounted_propagated=0
elapsed=0
while [ "$elapsed" -lt 180 ]; do
  current_mounted_sha="$(pkubectl exec -n staging "$staging_pod_1" -- sha256sum /etc/secret/message 2>/dev/null | awk '{print $1}')"
  if [ "$current_mounted_sha" = "$staging_source_sha_2" ]; then
    mounted_propagated=1
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
if [ "$mounted_propagated" -eq 1 ]; then
  echo "OK: staging mounted file propagated the rotated value within ${elapsed}s, no Pod restart required (sha256 $current_mounted_sha)"
else
  echo "FAIL: staging mounted file did not propagate the rotated value within 180s" >&2
  fail=1
fi

# --- 16. production remains fully unchanged ---
production_target_rv_after="$(pkubectl get secret "$production_target" -n production -o jsonpath='{.metadata.resourceVersion}')"
production_pod_uid_after="$(pkubectl get pod "$production_pod_1" -n production -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
production_target_sha_after="$(pkubectl get secret "$production_target" -n production -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
if [ "$production_target_rv_before" = "$production_target_rv_after" ] \
  && [ "$production_pod_uid_before" = "$production_pod_uid_after" ] \
  && [ "$production_target_sha_after" = "$production_target_sha_1" ]; then
  echo "OK: production target Secret resourceVersion, Pod UID, and hash are all unchanged (isolation proof)"
else
  echo "FAIL: production changed during staging's rotation (rv: $production_target_rv_before -> $production_target_rv_after; uid: $production_pod_uid_before -> $production_pod_uid_after; hash: $production_target_sha_1 -> $production_target_sha_after)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-secret-lifecycle: FAILED before target-Secret deletion/recreation test" >&2
  exit 1
fi

# --- 17 (per this task's numbering)/14 (per the plan): delete the
# staging target Secret manually and confirm ESO recreates it with the
# same (rotated) value, within refreshInterval. ---
echo "test-secret-lifecycle: deleting the staging target Secret to prove ESO recreates it ..."
staging_target_uid_before_delete="$(pkubectl get secret "$staging_target" -n staging -o jsonpath='{.metadata.uid}')"
pkubectl delete secret "$staging_target" -n staging
recreated=0
elapsed=0
while [ "$elapsed" -lt 90 ]; do
  if pkubectl get secret "$staging_target" -n staging >/dev/null 2>&1; then
    recreated_sha="$(pkubectl get secret "$staging_target" -n staging -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
    if [ "$recreated_sha" = "$staging_source_sha_2" ]; then
      recreated=1
      break
    fi
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
if [ "$recreated" -eq 1 ]; then
  staging_target_uid_after_delete="$(pkubectl get secret "$staging_target" -n staging -o jsonpath='{.metadata.uid}')"
  echo "OK: ESO recreated the deleted target Secret with the same value within ${elapsed}s (new UID, as expected for a fresh object: before=$staging_target_uid_before_delete after=$staging_target_uid_after_delete)"
else
  echo "FAIL: ESO did not recreate the deleted target Secret within 90s" >&2
  fail=1
fi

# --- 18/15 (per the plan's numbering): re-run bootstrap and confirm a
# true no-op on the chart-rendered GitOps resources. ---
echo "test-secret-lifecycle: re-running gitops-bootstrap, expecting a true no-op ..."
staging_ss_rv_1="$(pkubectl get secretstore staging-kubernetes-backend -n staging -o jsonpath='{.metadata.resourceVersion}')"
staging_es_rv_1="$(pkubectl get externalsecret platform-smoke-staging-standard-workload-secret -n staging -o jsonpath='{.metadata.resourceVersion}')"
make gitops-bootstrap REVISION="$current_branch"
staging_ss_rv_2="$(pkubectl get secretstore staging-kubernetes-backend -n staging -o jsonpath='{.metadata.resourceVersion}')"
staging_es_rv_2="$(pkubectl get externalsecret platform-smoke-staging-standard-workload-secret -n staging -o jsonpath='{.metadata.resourceVersion}')"
if [ "$staging_ss_rv_1" = "$staging_ss_rv_2" ] && [ "$staging_es_rv_1" = "$staging_es_rv_2" ]; then
  echo "OK: re-running gitops-bootstrap is a true no-op (SecretStore/ExternalSecret resourceVersion unchanged)"
else
  echo "FAIL: gitops-bootstrap re-run was not a no-op (SecretStore rv $staging_ss_rv_1 -> $staging_ss_rv_2; ExternalSecret rv $staging_es_rv_1 -> $staging_es_rv_2)" >&2
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

pkubectl get secret "$staging_target" -n staging >/dev/null 2>&1 && echo "OK: staging target Secret survives ESO uninstall" || { echo "FAIL: staging target Secret was deleted by ESO uninstall" >&2; fail=1; }
pkubectl get secret "$production_target" -n production >/dev/null 2>&1 && echo "OK: production target Secret survives ESO uninstall" || { echo "FAIL: production target Secret was deleted by ESO uninstall" >&2; fail=1; }

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
# removed - only its two scoped releases were, in the block above). As
# in step 6, this uses an in-place `kubectl apply` back to main rather
# than lab/gitops/uninstall.sh + gitops-bootstrap, for the same reason:
# that script's namespace-inventory check does not account for ESO's
# scoped-RBAC objects now living in staging/production and would again
# refuse to clean up, after already cascading a delete through the
# generated Applications' managed resources. The source Secrets
# provisioned in step 5/13 (eso-source-staging/eso-source-production)
# are deliberately NOT deleted here: they are outside Git/Helm/Argo CD
# entirely, and once this PR merges, main's own
# values-staging.yaml/values-production.yaml will need them to already
# exist for the ExternalSecrets to reconcile immediately. ---
echo "test-secret-lifecycle: restoring persistent state (ESO reinstall + GitOps back to main, in-place apply) ..."
sh lab/eso/install.sh
main_apply_file="$(gitops_render_root_app_for_revision main)"
pkubectl apply -f "$main_apply_file"
echo "OK: root Application updated in place back to revision 'main' (no delete, no cascade)"

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
wait_for_no_out_of_sync_resources() {
  app="$1"; timeout="${2:-180}"
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    remaining="$(pkubectl get application "$app" -n argocd -o jsonpath='{.status.resources[?(@.status=="OutOfSync")].kind}' 2>/dev/null)"
    if [ -z "$remaining" ]; then
      echo "OK: Application/$app has zero OutOfSync resources"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "FAIL: Application/$app still has OutOfSync resource(s) after ${timeout}s: $remaining" >&2
  return 1
}
for app in platform-bootstrap $GITOPS_GENERATED_APPS; do
  wait_for_no_out_of_sync_resources "$app" 180 || fail=1
done

# Empirically discovered on this exact cluster: once the AppProject
# (now back at main's definition) drops SecretStore/ExternalSecret from
# its namespaceResourceWhitelist, Argo CD's sync/prune can no longer
# see or manage existing live objects of those kinds at all - they are
# outside what the Application is permitted to reconcile, so "Synced"
# is reported without them ever being pruned. Reverting a kind out of
# the whitelist does not retroactively clean up what it already
# created; that cleanup has to be explicit. Deleted here (never
# recreated by anything on main) - the target Secrets go with them,
# since nothing on main references them and retaining orphaned Secrets
# would not be a faithful restore of the pre-test baseline.
#
# Also observed empirically: deleting a resource that still carries the
# argocd.argoproj.io/tracking-id annotation can make self-heal briefly
# react as if a tracked resource "disappeared" and try to recreate it
# from a stale, branch-sourced manifest snapshot - always failing
# (correctly - the whitelist blocks it) and retrying with backoff for a
# few minutes before Argo CD's own retry budget exhausts and it settles
# permanently. Stripping the tracking annotation first, before
# deleting, avoids ever entering that transient retry storm. ---
for res in "secretstore staging-kubernetes-backend staging" "secretstore production-kubernetes-backend production" \
  "externalsecret $staging_target staging" "externalsecret $production_target production" \
  "secret $staging_target staging" "secret $production_target production"; do
  set -- $res
  pkubectl annotate "$1" "$2" -n "$3" argocd.argoproj.io/tracking-id- >/dev/null 2>&1 || true
  pkubectl delete "$1" "$2" -n "$3" --ignore-not-found >/dev/null 2>&1 || true
done

# Stabilization gate: require the absence of those objects AND a fully
# Synced/Healthy, zero-OutOfSync state on both generated Applications
# to hold for 3 consecutive checks (45s), not just once - this is what
# actually distinguishes "converged" from "transiently clean, about to
# oscillate again," which a single read cannot tell apart.
stable_checks=0
elapsed=0
while [ "$elapsed" -lt 420 ] && [ "$stable_checks" -lt 3 ]; do
  clean=1
  pkubectl get secretstore staging-kubernetes-backend -n staging >/dev/null 2>&1 && clean=0
  pkubectl get secretstore production-kubernetes-backend -n production >/dev/null 2>&1 && clean=0
  pkubectl get externalsecret "$staging_target" -n staging >/dev/null 2>&1 && clean=0
  pkubectl get externalsecret "$production_target" -n production >/dev/null 2>&1 && clean=0
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
  echo "OK: no SecretStore/ExternalSecret remains after restoring to main, stable across 3 consecutive checks (not yet merged, so main correctly does not render them; explicitly cleaned up since a kind dropped from the AppProject whitelist is no longer prunable by Argo CD itself)"
else
  echo "FAIL: cluster state did not stabilize (no SecretStore/ExternalSecret, both Applications Synced/Healthy) within 420s after restoring to main" >&2
  fail=1
fi
pkubectl rollout status deployment/platform-smoke-staging-standard-workload -n staging --timeout=120s >/dev/null
pkubectl rollout status deployment/platform-smoke-production-standard-workload -n production --timeout=120s >/dev/null
echo "OK: staging and production workload Deployments are Available again on main"

# --- final health check (Phase 2.6.1 ESO bootstrap baseline) ---
sh tests/eso/test-runtime-health.sh || fail=1

# --- 21: global kubeconfig/context/cluster-list isolation re-check ---
if [ -f "$global_kubeconfig" ]; then
  global_sha_after="$(shasum -a 256 "$global_kubeconfig" | awk '{print $1}')"
else
  global_sha_after="<absent>"
fi
global_ctx_after="$(command -v kubectl >/dev/null 2>&1 && kubectl config current-context 2>/dev/null || echo "<no-global-kubectl>")"
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
