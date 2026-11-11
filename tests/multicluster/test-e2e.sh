#!/bin/sh
# Mutating Phase 2.7.4 end-to-end test (ADR-0015; plan
# .local/evidence/phase-2.7.4-cluster-generator-per-spoke-eso-plan.md).
# Requires REVISION (a pushed branch), no lab-multicluster member and no
# lab-lite running, the pinned Argo CD and ESO charts already fetched,
# and gh authenticated as the repository owner (repo-setup reuses the
# existing deploy key). SPOKES selects the spokes (default dev,uat;
# must include dev and uat - they are the isolation pair). Backs
# `make mc-test-e2e`.
#
# Proves: `make mc-up` from nothing and as a no-op; the clusters
# generator creates exactly one Application per registered spoke, none
# for the hub, none for an unlabelled or out-of-list (qa) cluster
# Secret; each spoke runs its workload with an ESO-synced Secret
# matching its source; rotating dev's source changes dev only;
# self-heal in dev leaves uat untouched; deregistering dev removes its
# Application and workloads without a stuck finalizer and leaves uat
# alone, and re-registering restores it; `gitops-uninstall` on the hub
# cascades to the spokes and keeps Argo CD, the repository Secret and
# the cluster Secrets; a re-bootstrap converges again. Destroys the
# profile at the end unless LAB_MC_KEEP=1. Never prints a token or a
# secret value - only SHA-256 hashes, names and states.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
LAB_CLUSTER=hub
export LAB_CLUSTER
. scripts/lab/_lib.sh
require_repo_root
require_tools
. scripts/argocd/_lib.sh
. scripts/gitops/_lib.sh
. lab/multicluster/_lib.sh

revision="${REVISION:?REVISION is required (a pushed branch)}"
export REVISION
spokes="$(lab_mc_spokes)"
case " $spokes " in *" dev "*) ;; *) echo "FAIL: SPOKES must include dev (isolation pair dev/uat)" >&2; exit 1 ;; esac
case " $spokes " in *" uat "*) ;; *) echo "FAIL: SPOKES must include uat (isolation pair dev/uat)" >&2; exit 1 ;; esac
fail=0
t0="$(date +%s)"

read -r global_sha_before global_ctx_before <<EOF
$(global_kubeconfig_fingerprint)
EOF

target_secret() { printf 'platform-smoke-%s-standard-workload-secret' "$1"; }
deployment() { printf 'platform-smoke-%s-standard-workload' "$1"; }
configmap() { printf 'platform-smoke-%s-standard-workload-config' "$1"; }
target_sha() {
  ckubectl "$1" -n "$1" get secret "$(target_secret "$1")" -o jsonpath='{.data.message}' 2>/dev/null | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}'
}
wait_target_sha() {
  # $1 spoke, $2 expected sha, $3 timeout s
  wts_i=0
  while [ "$wts_i" -lt "$3" ]; do
    [ "$(target_sha "$1")" = "$2" ] && return 0
    sleep 5; wts_i=$((wts_i + 5))
  done
  return 1
}
app_count() {
  pkubectl -n "$ARGOCD_NAMESPACE" get applications -l "${GITOPS_NS_OWNER_LABEL_KEY}=${GITOPS_NS_OWNER_LABEL_VALUE}" -o name 2>/dev/null | grep -c 'platform-smoke-' || true
}
value_file="$(mktemp)"
chmod 600 "$value_file"
decoys="spoke-qa spoke-unlabelled"
cleanup() {
  rm -f "$value_file"
  for d in $decoys; do
    ckubectl "$LAB_MC_HUB" -n argocd delete secret "$d" --ignore-not-found >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM
new_value() { printf 'lab-%s-%s' "$(date +%s)" "$(head -c 16 /dev/urandom | shasum -a 256 | cut -c1-24)"; }

# --- 0. preconditions ---
for m in "$LAB_MC_HUB" $LAB_MC_ALL_SPOKES; do
  if LAB_CLUSTER="$m" sh -c '. scripts/lab/_lib.sh; kind_cluster_exists' 2>/dev/null; then
    echo "FAIL: lab-multicluster member '$m' already exists - run 'make lab-mc-destroy' first (this test starts from nothing)" >&2
    exit 1
  fi
done
gitops_remote_revision_exists "$revision" || { echo "FAIL: remote revision '$revision' does not exist - push it first" >&2; exit 1; }
echo "OK: step 0 - no multicluster member exists; revision '$revision' exists"

# --- 1. mc-up from nothing, then as a no-op ---
new_value > "$value_file"
initial_sha="$(shasum -a 256 "$value_file" | awk '{print $1}')"
MC_SOURCE_VALUE_FILE="$value_file" sh lab/multicluster/up.sh
for s in $spokes; do
  gitops_wait_for_synced_healthy "platform-smoke-$s" 300 || fail=1
done
echo "OK: step 1a - mc-up from nothing converged in $(( $(date +%s) - t0 ))s"

snapshot() {
  for s in $spokes; do
    printf '%s app=%s secret=%s eso=%s src=%s\n' "$s" \
      "$(gitops_app_uid "platform-smoke-$s")" \
      "$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.metadata.resourceVersion}')" \
      "$(ckubectl "$s" -n "eso-$s" get secret -l "owner=helm,name=eso-$s" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')" \
      "$(ckubectl "$s" -n "eso-source-$s" get secret "local-backend-$s" -o jsonpath='{.metadata.resourceVersion}')"
  done
  printf 'root gen=%s\n' "$(gitops_app_generation "$GITOPS_ROOT_APP_NAME")"
}
snap1="$(snapshot)"
MC_SOURCE_VALUE_FILE="$value_file" sh lab/multicluster/up.sh >/dev/null
snap2="$(snapshot)"
if [ "$snap1" = "$snap2" ]; then
  echo "OK: step 1b - second mc-up is a no-op (Application UIDs, cluster Secret and source Secret resourceVersions, Helm release revisions, root generation unchanged)"
else
  echo "FAIL: step 1b - second mc-up changed state:" >&2
  printf 'before:\n%s\nafter:\n%s\n' "$snap1" "$snap2" >&2
  fail=1
fi

# --- 2. exactly one Application per registered spoke, by cluster name ---
expected_apps="$(for s in $spokes; do printf 'platform-smoke-%s\n' "$s"; done | sort | tr '\n' ' ' | sed 's/ $//')"
actual_apps="$(gitops_generated_apps)"
n_apps="$(app_count)"
if [ "$actual_apps" = "$expected_apps" ] && [ "$n_apps" = "$(echo "$spokes" | wc -w | tr -d ' ')" ]; then
  echo "OK: step 2 - exactly one generated Application per registered spoke ($actual_apps)"
else
  echo "FAIL: step 2 - generated Applications '$actual_apps' (count $n_apps), expected '$expected_apps'" >&2
  fail=1
fi
for s in $spokes; do
  dest="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "platform-smoke-$s" -o jsonpath='{.spec.destination.name}|{.spec.destination.server}|{.spec.destination.namespace}')"
  if [ "$dest" = "spoke-$s||$s" ]; then
    echo "OK: step 2 - platform-smoke-$s targets cluster name spoke-$s, namespace $s (no server URL)"
  else
    echo "FAIL: step 2 - platform-smoke-$s destination '$dest', expected 'spoke-$s||$s'" >&2
    fail=1
  fi
done

# --- 3. nothing lands on the hub ---
hub_hits=""
for ns in $LAB_MC_ALL_SPOKES; do
  ckubectl "$LAB_MC_HUB" get namespace "$ns" >/dev/null 2>&1 && hub_hits="$hub_hits ns/$ns"
done
hub_deploys="$(ckubectl "$LAB_MC_HUB" get deployments -A -o name 2>/dev/null | grep -c 'platform-smoke-' || true)"
if [ -z "$hub_hits" ] && [ "$hub_deploys" = "0" ]; then
  echo "OK: step 3 - the hub has no dev/uat/prod namespace and no platform-smoke Deployment"
else
  echo "FAIL: step 3 - workload objects on the hub:$hub_hits deployments=$hub_deploys" >&2
  fail=1
fi
dest_server="$(pkubectl -n "$ARGOCD_NAMESPACE" get appproject "$GITOPS_PROJECT_NAME" -o jsonpath='{.spec.destinations[*].server}')"
if [ -z "$dest_server" ]; then
  echo "OK: step 3 - AppProject '$GITOPS_PROJECT_NAME' allows no server-addressed (in-cluster) destination"
else
  echo "FAIL: step 3 - AppProject allows server destination(s): $dest_server" >&2
  fail=1
fi

# --- 4. decoy cluster Secrets never generate an Application ---
for d in $decoys; do
  case "$d" in
    spoke-qa) extra_label="${LAB_MC_ENV_LABEL_KEY}: qa"; d_ns=qa ;;
    *) extra_label="${LAB_MC_OWNER_LABEL_KEY%%/*}/decoy: \"true\""; d_ns=dev ;;
  esac
  cat <<EOF | ckubectl "$LAB_MC_HUB" apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${d}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}
    ${extra_label}
type: Opaque
stringData:
  name: ${d}
  server: https://eks-gitops-${d#spoke-}-control-plane:6443
  namespaces: ${d_ns}
  clusterResources: "false"
  config: '{"tlsClientConfig":{"insecure":false}}'
EOF
done
pkubectl -n "$ARGOCD_NAMESPACE" annotate applicationset "$GITOPS_APPSET_NAME" "argocd.argoproj.io/application-set-refresh=true" --overwrite >/dev/null 2>&1 || true
sleep 30
if [ "$(app_count)" = "$n_apps" ] && ! pkubectl -n "$ARGOCD_NAMESPACE" get application platform-smoke-qa >/dev/null 2>&1; then
  echo "OK: step 4 - a cluster Secret labelled platform.environment=qa and one without the label generated no Application (count still $n_apps)"
else
  echo "FAIL: step 4 - a decoy cluster Secret generated an Application (count $(app_count))" >&2
  fail=1
fi
for d in $decoys; do ckubectl "$LAB_MC_HUB" -n argocd delete secret "$d" --ignore-not-found >/dev/null; done
for s in $spokes; do
  gitops_wait_for_synced_healthy "platform-smoke-$s" 60 >/dev/null || { echo "FAIL: step 4 - platform-smoke-$s not Synced/Healthy after the decoys" >&2; fail=1; }
done

# --- 5. per-spoke workload + ESO ---
for s in $spokes; do
  av="$(ckubectl "$s" -n "$s" get deployment "$(deployment "$s")" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  es="$(ckubectl "$s" -n "$s" get externalsecret "$(deployment "$s")-secret" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "${av:-0}" -ge 1 ] 2>/dev/null && [ "$es" = "True" ] && wait_target_sha "$s" "$initial_sha" 90; then
    echo "OK: step 5 - '$s': Deployment Available ($av), ExternalSecret Ready, target Secret sha256 matches its source"
  else
    echo "FAIL: step 5 - '$s': available='$av' externalsecret-ready='$es' target-sha='$(target_sha "$s")'" >&2
    fail=1
  fi
done
echo "--- memory (Docker view) after convergence ---"
sh lab/multicluster/status.sh 2>/dev/null | grep -iE 'mem|MiB|GiB' || true

# --- 6. rotation in dev reaches dev only ---
uat_rv_before="$(ckubectl uat -n uat get secret "$(target_secret uat)" -o jsonpath='{.metadata.resourceVersion}')"
uat_sha_before="$(target_sha uat)"
new_value > "$value_file"
rotated_sha="$(shasum -a 256 "$value_file" | awk '{print $1}')"
LAB_CLUSTER=dev sh lab/eso/provision-source-secret.sh dev --rotate < "$value_file" >/dev/null
if wait_target_sha dev "$rotated_sha" 150; then
  echo "OK: step 6 - dev target Secret converged to the rotated source"
else
  echo "FAIL: step 6 - dev target Secret did not converge to the rotated source within 150s" >&2
  fail=1
fi
uat_rv_after="$(ckubectl uat -n uat get secret "$(target_secret uat)" -o jsonpath='{.metadata.resourceVersion}')"
if [ "$uat_rv_after" = "$uat_rv_before" ] && [ "$(target_sha uat)" = "$uat_sha_before" ]; then
  echo "OK: step 6 - uat target Secret untouched (resourceVersion $uat_rv_after, sha256 unchanged)"
else
  echo "FAIL: step 6 - uat target Secret changed after rotating dev (rv $uat_rv_before -> $uat_rv_after)" >&2
  fail=1
fi

# --- 7. self-heal in dev leaves uat alone ---
uat_cm_rv="$(ckubectl uat -n uat get configmap "$(configmap uat)" -o jsonpath='{.metadata.resourceVersion}')"
dev_cm_uid="$(ckubectl dev -n dev get configmap "$(configmap dev)" -o jsonpath='{.metadata.uid}')"
ckubectl dev -n dev delete configmap "$(configmap dev)" >/dev/null
i=0; healed=""
while [ "$i" -lt 180 ]; do
  healed="$(ckubectl dev -n dev get configmap "$(configmap dev)" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  [ -n "$healed" ] && [ "$healed" != "$dev_cm_uid" ] && break
  sleep 5; i=$((i + 5))
done
if [ -n "$healed" ] && [ "$healed" != "$dev_cm_uid" ]; then
  echo "OK: step 7 - dev ConfigMap deleted on the spoke and recreated by self-heal in ${i}s"
else
  echo "FAIL: step 7 - dev ConfigMap was not recreated within 180s" >&2
  fail=1
fi
if [ "$(ckubectl uat -n uat get configmap "$(configmap uat)" -o jsonpath='{.metadata.resourceVersion}')" = "$uat_cm_rv" ]; then
  echo "OK: step 7 - uat ConfigMap untouched (resourceVersion $uat_cm_rv)"
else
  echo "FAIL: step 7 - uat ConfigMap changed during dev self-heal" >&2
  fail=1
fi

# --- 8. deregister dev with a live Application, then re-register ---
uat_deploy_uid="$(ckubectl uat -n uat get deployment "$(deployment uat)" -o jsonpath='{.metadata.uid}')"
d0="$(date +%s)"
if sh lab/multicluster/spoke-deregister.sh dev; then
  echo "OK: step 8 - deregister dev completed in $(( $(date +%s) - d0 ))s"
else
  echo "FAIL: step 8 - deregister dev failed" >&2
  fail=1
fi
stuck="$(pkubectl -n "$ARGOCD_NAMESPACE" get applications -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{" "}{end}')"
if ! pkubectl -n "$ARGOCD_NAMESPACE" get application platform-smoke-dev >/dev/null 2>&1 \
   && ! pkubectl -n "$ARGOCD_NAMESPACE" get secret spoke-dev >/dev/null 2>&1 \
   && [ -z "$stuck" ]; then
  echo "OK: step 8 - Application platform-smoke-dev and cluster Secret spoke-dev gone; no Application stuck in deletion"
else
  echo "FAIL: step 8 - after deregister: app/secret still present or stuck Applications '$stuck'" >&2
  fail=1
fi
dev_left="$(ckubectl dev -n dev get deployment,configmap,service,externalsecret,secretstore,networkpolicy,poddisruptionbudget -o name 2>/dev/null | grep -c 'platform-smoke-dev' || true)"
if [ "$dev_left" = "0" ] && ckubectl dev get namespace dev >/dev/null 2>&1; then
  echo "OK: step 8 - dev workloads removed on the spoke by the Application's finalizer; namespace dev kept"
else
  echo "FAIL: step 8 - dev spoke still has $dev_left platform-smoke-dev object(s), or namespace dev is gone" >&2
  fail=1
fi
if [ "$(ckubectl uat -n uat get deployment "$(deployment uat)" -o jsonpath='{.metadata.uid}')" = "$uat_deploy_uid" ] \
   && gitops_wait_for_synced_healthy platform-smoke-uat 30 >/dev/null; then
  echo "OK: step 8 - uat unaffected (same Deployment UID, Synced/Healthy)"
else
  echo "FAIL: step 8 - uat affected by deregistering dev" >&2
  fail=1
fi
MC_SOURCE_VALUE_FILE="$value_file" sh lab/multicluster/up.sh >/dev/null
if gitops_wait_for_synced_healthy platform-smoke-dev 300 && wait_target_sha dev "$rotated_sha" 120; then
  echo "OK: step 8 - re-registered dev via mc-up: platform-smoke-dev Synced/Healthy again, target Secret matches the (rotated) source"
else
  echo "FAIL: step 8 - dev did not converge after re-registration" >&2
  fail=1
fi

# --- 9. gitops-uninstall on the hub cascades to the spokes ---
if sh lab/gitops/uninstall.sh; then
  echo "OK: step 9 - gitops-uninstall on the hub completed"
else
  echo "FAIL: step 9 - gitops-uninstall on the hub failed" >&2
  fail=1
fi
left_apps="$(pkubectl -n "$ARGOCD_NAMESPACE" get applications -o name 2>/dev/null | wc -l | tr -d ' ')"
spoke_left=0
for s in $spokes; do
  c="$(ckubectl "$s" -n "$s" get deployment,configmap,service,externalsecret,secretstore,networkpolicy,poddisruptionbudget -o name 2>/dev/null | grep -c "platform-smoke-$s" || true)"
  spoke_left=$((spoke_left + c))
done
kept_secrets="$(for s in $spokes; do pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o name 2>/dev/null; done | wc -l | tr -d ' ')"
if [ "$left_apps" = "0" ] && [ "$spoke_left" = "0" ] && argocd_release_exists \
   && gitops_repo_secret_exists && [ "$kept_secrets" = "$(echo "$spokes" | wc -w | tr -d ' ')" ]; then
  echo "OK: step 9 - every Application gone and every spoke workload removed; Argo CD, the repository Secret and all $kept_secrets cluster Secrets kept"
else
  echo "FAIL: step 9 - apps=$left_apps spoke-objects=$spoke_left argocd/repo/cluster-secrets kept=$kept_secrets" >&2
  fail=1
fi
sh lab/gitops/bootstrap.sh >/dev/null
for s in $spokes; do
  gitops_wait_for_synced_healthy "platform-smoke-$s" 300 || fail=1
done
echo "OK: step 9 - re-bootstrap converged"

# --- 10. restore ---
if [ "${LAB_MC_KEEP:-0}" = "1" ]; then
  echo "NOTE: LAB_MC_KEEP=1 - leaving the lab-multicluster profile running"
else
  sh lab/multicluster/destroy.sh >/dev/null
  echo "OK: step 10 - lab-multicluster profile destroyed"
fi
read -r global_sha_after global_ctx_after <<EOF
$(global_kubeconfig_fingerprint)
EOF
if [ "$global_sha_before" = "$global_sha_after" ] && [ "$global_ctx_before" = "$global_ctx_after" ]; then
  echo "OK: step 10 - global kubeconfig unchanged"
else
  echo "FAIL: step 10 - global kubeconfig changed" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "mc-test-e2e: FAILED ($(( $(date +%s) - t0 ))s)"
  exit 1
fi
echo "mc-test-e2e: OK ($spokes, $(( $(date +%s) - t0 ))s)"
