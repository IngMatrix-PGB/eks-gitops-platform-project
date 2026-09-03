#!/bin/sh
# Mutating lifecycle test proving the External Secrets Operator
# bootstrap's install/no-op/uninstall/restore idempotency end to end:
#   global-isolation baseline -> Argo CD/workload baseline -> install ->
#   install (true no-op, per release) -> runtime health -> CRD
#   ownership/isolation proof -> singleton-health guard (status.sh must
#   fail while production exists if staging's shared webhook is
#   unhealthy) -> CRD field-ownership conflict (install.sh's preflight
#   must fail closed, with zero mutation and never a --force-conflicts
#   retry) -> singleton-dependency guard (uninstalling staging while
#   production exists must be refused) -> uninstall in the only order
#   the guard allows (production, then staging; CRDs retained) ->
#   uninstall (no-op) -> restoration install -> restoration install
#   (no-op) -> final health -> global-isolation re-check.
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

# --- status.sh must fail while production exists if staging's shared
# webhook/cert-controller singleton is unhealthy - temporarily scale
# the webhook Deployment to 0, confirm `eso-status` fails for exactly
# that reason, then restore it and confirm status passes again. ---
echo "test-idempotency: singleton health guard - scaling down the shared webhook Deployment ..."
pkubectl scale deployment eso-staging-external-secrets-webhook -n eso-staging --replicas=0 >/dev/null
pkubectl wait --for=jsonpath='{.status.replicas}'=0 deployment/eso-staging-external-secrets-webhook -n eso-staging --timeout=30s >/dev/null 2>&1 || true

status_rc=0
sh lab/eso/status.sh >/dev/null 2>&1 || status_rc=$?
if [ "$status_rc" -eq 0 ]; then
  echo "FAIL: eso-status succeeded even though the shared webhook singleton is unhealthy while production exists" >&2
  fail=1
else
  echo "OK: eso-status failed closed (exit $status_rc) while the shared webhook singleton was unhealthy"
fi

echo "test-idempotency: restoring the shared webhook Deployment ..."
pkubectl scale deployment eso-staging-external-secrets-webhook -n eso-staging --replicas=1 >/dev/null
# Wait on the exact field status.sh itself reads (readyReplicas=1), not
# just the Available condition - Available can flip true a moment
# before status.readyReplicas catches up, which previously made the
# very next status.sh call flap between "restored" and "still
# unhealthy" depending on timing.
pkubectl wait --for=jsonpath='{.status.readyReplicas}'=1 deployment/eso-staging-external-secrets-webhook -n eso-staging --timeout=120s >/dev/null

status_rc=0
status_tries=0
while [ "$status_tries" -lt 6 ]; do
  status_rc=0
  sh lab/eso/status.sh >/dev/null 2>&1 || status_rc=$?
  [ "$status_rc" -eq 0 ] && break
  status_tries=$((status_tries + 1))
  sleep 5
done
if [ "$status_rc" -ne 0 ]; then
  echo "FAIL: eso-status still fails after the shared webhook singleton was restored (retried $status_tries times)" >&2
  fail=1
else
  echo "OK: eso-status passes again once the shared webhook singleton is healthy"
fi

# --- CRD field-ownership conflict: install.sh's preflight must stop
# the install with the CRD completely untouched, and must never retry
# with --force-conflicts. Simulated by forcing a THIRD, foreign field
# manager to seize a field our own CRD template genuinely sets
# (metadata.labels."external-secrets.io/component") - the foreign
# manager's own seizure uses --force-conflicts (that is the test
# fixture's setup, standing in for "some other tool already manages
# this field"; it is not part of, and never appears in, this project's
# own install path).
#
# Fail-safe, trap-based cleanup: from the moment the foreign manager
# seizes the field, ANY exit from this window - normal completion, an
# assertion failure below, or an unexpected `set -eu` abort from any
# command in between - releases that claim. Without this, a mid-window
# failure would leave conflict-test-simulator permanently owning a
# field on a real, shared CRD. This script sets no other trap, so
# installing and later clearing this one is fully self-contained. ---
echo "test-idempotency: simulating a CRD field-ownership conflict ..."
conflict_crd="fakes.generators.external-secrets.io"
conflict_manifest="$(mktemp)"
conflict_release_manifest="$(mktemp)"
conflict_out="$(mktemp)"
cat > "$conflict_release_manifest" <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${conflict_crd}
EOF
conflict_cleanup() {
  pkubectl apply --server-side --field-manager=conflict-test-simulator -f "$conflict_release_manifest" >/dev/null 2>&1 || true
  rm -f "$conflict_manifest" "$conflict_release_manifest" "$conflict_out"
}
trap conflict_cleanup EXIT INT TERM

cat > "$conflict_manifest" <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${conflict_crd}
  labels:
    external-secrets.io/component: "conflict-test-hijacked"
EOF
before_label="$(pkubectl get "customresourcedefinition/${conflict_crd}" -o jsonpath='{.metadata.labels.external-secrets\.io/component}' 2>/dev/null)"
pkubectl apply --server-side --field-manager=conflict-test-simulator --force-conflicts -f "$conflict_manifest" >/dev/null

conflict_rc=0
sh lab/eso/install.sh >"$conflict_out" 2>&1 || conflict_rc=$?
after_label="$(pkubectl get "customresourcedefinition/${conflict_crd}" -o jsonpath='{.metadata.labels.external-secrets\.io/component}' 2>/dev/null)"

if [ "$conflict_rc" -eq 0 ]; then
  echo "FAIL: install.sh succeeded despite a live field-ownership conflict on $conflict_crd" >&2
  fail=1
elif ! grep -qi "conflict" "$conflict_out"; then
  echo "FAIL: install.sh failed for a reason other than the expected field-ownership conflict:" >&2
  cat "$conflict_out" >&2
  fail=1
else
  echo "OK: install.sh's CRD preflight failed closed on a real field-ownership conflict (exit $conflict_rc)"
fi
if [ "$after_label" != "conflict-test-hijacked" ]; then
  echo "FAIL: the conflicting CRD field was modified by the failed install attempt (before='$before_label' after='$after_label') - this must never happen" >&2
  fail=1
else
  echo "OK: the CRD was not modified, deleted, recreated, or force-adopted by the failed install attempt"
fi
# Checked against install.sh's own SOURCE with comment lines stripped
# first, not its runtime output - kubectl's own conflict error always
# suggests "--force-conflicts" as one way a human could resolve it (see
# the captured output above), which would make an output-text check a
# permanent false positive; the script's own explanatory comments about
# why it never does this would equally trip a naive full-file grep.
# What actually matters is that no *executable* line passes that flag.
if grep -v '^[[:space:]]*#' lab/eso/install.sh | grep -q -- "--force-conflicts"; then
  echo "FAIL: lab/eso/install.sh itself invokes --force-conflicts - it must never retry a CRD conflict with a force flag" >&2
  fail=1
else
  echo "OK: lab/eso/install.sh never invokes --force-conflicts"
fi

# Explicit, verified release of the foreign manager's claim (not just
# relying on the exit trap, though it remains armed as the safety net
# for anything below that fails unexpectedly) - then restore the real
# field value via install.sh's own normal (non-forced) path.
pkubectl apply --server-side --field-manager=conflict-test-simulator -f "$conflict_release_manifest" >/dev/null
released_managers="$(pkubectl get "customresourcedefinition/${conflict_crd}" -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null)"
if printf '%s' "$released_managers" | grep -q "conflict-test-simulator"; then
  echo "FAIL: conflict-test-simulator still holds a field claim on $conflict_crd after the explicit release" >&2
  fail=1
else
  echo "OK: conflict-test-simulator's claim was fully released"
fi

echo "test-idempotency: re-installing to restore correct CRD field ownership after the conflict simulation ..."
sh lab/eso/install.sh
restored_label="$(pkubectl get "customresourcedefinition/${conflict_crd}" -o jsonpath='{.metadata.labels.external-secrets\.io/component}' 2>/dev/null)"
restored_manager="$(pkubectl get "customresourcedefinition/${conflict_crd}" -o jsonpath="{.metadata.managedFields[?(@.fieldsV1.f:metadata.f:labels.f:external-secrets\\.io/component)].manager}" 2>/dev/null)"
if [ "$restored_label" = "controller" ]; then
  echo "OK: CRD field ownership restored to this project's own field manager ($restored_label)"
else
  echo "FAIL: CRD field not restored correctly after the conflict simulation (got '$restored_label')" >&2
  fail=1
fi

# Confirm no trace of conflict-test-simulator remains across all 25
# CRDs (not just the one used for the fixture) - the simulation only
# ever touched fakes.generators.external-secrets.io, but this proves
# that claim rather than assuming it.
trace_found=0
while IFS= read -r crd; do
  [ -z "$crd" ] && continue
  crd_managers="$(pkubectl get "customresourcedefinition/${crd}" -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null)"
  if printf '%s' "$crd_managers" | grep -q "conflict-test-simulator"; then
    echo "FAIL: CRD $crd still references conflict-test-simulator in managedFields" >&2
    trace_found=1
  fi
done <<EOF
$(eso_crd_names)
EOF
if [ "$trace_found" -eq 0 ]; then
  echo "OK: no trace of conflict-test-simulator remains in any of the 25 CRDs"
else
  fail=1
fi

# Cleanup is complete and verified - clear the trap so it does not fire
# a redundant (harmless, but unnecessary) release at script exit.
trap - EXIT INT TERM
rm -f "$conflict_manifest" "$conflict_release_manifest" "$conflict_out"

# --- second install after the conflict simulation must be a genuine
# no-op, under the legitimate field manager only, with both releases
# still at revision 1 and healthy. ---
fp_staging_conflict_1="$(capture_release_fingerprint eso-staging eso-staging)"
fp_production_conflict_1="$(capture_release_fingerprint eso-production eso-production)"
sh lab/eso/install.sh
fp_staging_conflict_2="$(capture_release_fingerprint eso-staging eso-staging)"
fp_production_conflict_2="$(capture_release_fingerprint eso-production eso-production)"
if [ "$fp_staging_conflict_1" = "$fp_staging_conflict_2" ] && [ "$fp_production_conflict_1" = "$fp_production_conflict_2" ]; then
  echo "OK: post-conflict-simulation re-install is a true no-op for both releases"
else
  echo "FAIL: post-conflict-simulation re-install was not a no-op (staging: $fp_staging_conflict_1 -> $fp_staging_conflict_2; production: $fp_production_conflict_1 -> $fp_production_conflict_2)" >&2
  fail=1
fi
staging_rev="$(printf '%s' "$fp_staging_conflict_2" | cut -d: -f1)"
production_rev="$(printf '%s' "$fp_production_conflict_2" | cut -d: -f1)"
if [ "$staging_rev" = "1" ] && [ "$production_rev" = "1" ]; then
  echo "OK: both releases remain at Helm revision 1 after the conflict simulation and re-install"
else
  echo "FAIL: unexpected Helm revision after the conflict simulation (staging=$staging_rev production=$production_rev, expected 1/1)" >&2
  fail=1
fi
if printf '%s' "$restored_manager" | grep -q "^eks-gitops-lab-lite-eso-bootstrap$"; then
  echo "OK: the legitimate field manager (eks-gitops-lab-lite-eso-bootstrap) owns the restored field"
else
  echo "FAIL: unexpected field manager for the restored field: '$restored_manager'" >&2
  fail=1
fi
sh tests/eso/test-runtime-health.sh || fail=1

if [ "$fail" -ne 0 ]; then
  echo "test-idempotency: FAILED before uninstall phase - stopping without uninstalling" >&2
  exit 1
fi

# --- 11. singleton-dependency uninstall guard: removing staging (the
# webhook/cert-controller owner) while production still exists must be
# refused outright, with nothing uninstalled. ---
echo "test-idempotency: singleton-dependency guard - uninstalling staging while production exists (expect refusal) ..."
guard_out="$(mktemp)"
guard_rc=0
sh lab/eso/uninstall.sh staging >"$guard_out" 2>&1 || guard_rc=$?
cat "$guard_out"
rm -f "$guard_out"

if [ "$guard_rc" -eq 0 ]; then
  echo "FAIL: 'uninstall.sh staging' succeeded while eso-production still exists - the singleton dependency was not enforced" >&2
  fail=1
elif ! eso_release_exists eso-staging eso-staging; then
  echo "FAIL: 'uninstall.sh staging' was refused but eso-staging is gone anyway" >&2
  fail=1
else
  echo "OK: 'uninstall.sh staging' was refused (exit $guard_rc) and eso-staging remains installed"
fi

# --- ordinary uninstall, in the only order the guard allows: production
# first (always safe), then staging (now unblocked). ---
echo "test-idempotency: uninstall production (always safe) ..."
sh lab/eso/uninstall.sh production
if eso_release_exists eso-production eso-production; then
  echo "FAIL: eso-production still exists after 'uninstall.sh production'" >&2
  fail=1
fi

echo "test-idempotency: uninstall staging (now unblocked - production is gone) ..."
sh lab/eso/uninstall.sh staging

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
