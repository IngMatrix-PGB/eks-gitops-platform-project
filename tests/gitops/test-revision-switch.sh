#!/bin/sh
# Mutating pre-merge test for Phase 2.6.3a's switch-revision.sh (Gap
# 2). Requires REVISION (a pushed feature branch, distinct from main)
# so the switch has somewhere real to go. Proves: a nonexistent
# revision fails closed with zero mutation; an in-place switch
# preserves the root Application's UID and finalizers (never a
# delete+recreate); workloads stay available; the stale-operation
# detector/remediation helpers work correctly; switching back to main
# converges too, ending with the root Application's UID unchanged
# throughout the whole test. Backs `make gitops-test-revision-switch`
# only.
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

revision="${REVISION:?REVISION is required, e.g. REVISION=feat/phase-2.6.3a-transactional-gitops-lifecycle}"

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm
if ! argocd_release_exists; then
  echo "FAIL: Argo CD is not installed" >&2
  exit 1
fi
if ! gitops_root_app_exists; then
  echo "FAIL: root Application '$GITOPS_ROOT_APP_NAME' does not exist - bootstrap first" >&2
  exit 1
fi

fail=0

echo "test-revision-switch: step 1 - capture baseline"
baseline_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
baseline_finalizers="$(gitops_app_finalizers "$GITOPS_ROOT_APP_NAME")"
baseline_revision="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.targetRevision}')"
echo "OK: baseline captured (revision=$baseline_revision uid=$baseline_uid)"

echo "test-revision-switch: step 2 - a nonexistent revision must fail closed with zero mutation"
bogus_out="$(mktemp)"
if sh lab/gitops/switch-revision.sh "this-branch-does-not-exist-$(date +%s)" >"$bogus_out" 2>&1; then
  echo "FAIL: switch-revision.sh should have failed for a nonexistent revision" >&2
  cat "$bogus_out" >&2
  fail=1
else
  echo "OK: switch-revision.sh correctly refused a nonexistent revision"
fi
rm -f "$bogus_out"
post_bogus_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
post_bogus_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.targetRevision}')"
if [ "$post_bogus_uid" != "$baseline_uid" ] || [ "$post_bogus_rev" != "$baseline_revision" ]; then
  echo "FAIL: a rejected revision switch still mutated the root Application (uid: $baseline_uid -> $post_bogus_uid; revision: $baseline_revision -> $post_bogus_rev)" >&2
  fail=1
else
  echo "OK: zero mutation after the rejected switch attempt"
fi

if [ "$fail" -ne 0 ]; then
  echo "test-revision-switch: FAILED before attempting the real switch" >&2
  exit 1
fi

echo "test-revision-switch: step 3 - switching to '$revision' in place"
sh lab/gitops/switch-revision.sh "$revision"
mid_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
mid_finalizers="$(gitops_app_finalizers "$GITOPS_ROOT_APP_NAME")"
mid_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.targetRevision}')"
if [ "$mid_uid" = "$baseline_uid" ]; then
  echo "OK: root Application UID unchanged across the switch ($mid_uid) - confirmed patch, not delete+recreate"
else
  echo "FAIL: root Application UID changed across the switch ($baseline_uid -> $mid_uid)" >&2
  fail=1
fi
if [ "$mid_finalizers" = "$baseline_finalizers" ]; then
  echo "OK: root Application finalizers unchanged across the switch"
else
  echo "FAIL: root Application finalizers changed across the switch ($baseline_finalizers -> $mid_finalizers)" >&2
  fail=1
fi
if [ "$mid_rev" = "$revision" ]; then
  echo "OK: root Application is now at revision '$revision'"
else
  echo "FAIL: root Application revision mismatch (expected '$revision', got '$mid_rev')" >&2
  fail=1
fi

echo "test-revision-switch: step 4 - workloads remain available after the switch"
pkubectl rollout status deployment/platform-smoke-staging-standard-workload -n staging --timeout=180s >/dev/null
pkubectl rollout status deployment/platform-smoke-production-standard-workload -n production --timeout=180s >/dev/null
echo "OK: staging and production workload Deployments are Available"

echo "test-revision-switch: step 5 - stale-operation detection/remediation (functional proof, never a decoded value)"
pkubectl patch application "$GITOPS_ROOT_APP_NAME" -n "$ARGOCD_NAMESPACE" --type=merge \
  -p "{\"operation\":{\"initiatedBy\":{\"automated\":true},\"sync\":{\"revision\":\"$mid_rev\",\"source\":{\"repoURL\":\"$GITOPS_REPO_URL\",\"path\":\"$GITOPS_CHART_PATH\",\"targetRevision\":\"phase-2.6.3a-injected-stale-marker\"}}}}" >/dev/null
if gitops_detect_stale_operation "$GITOPS_ROOT_APP_NAME"; then
  echo "OK: gitops_detect_stale_operation correctly detected the injected stale operation"
else
  echo "FAIL: gitops_detect_stale_operation did not detect the injected stale operation" >&2
  fail=1
fi
gitops_clear_stale_operation "$GITOPS_ROOT_APP_NAME"
if gitops_detect_stale_operation "$GITOPS_ROOT_APP_NAME"; then
  echo "FAIL: stale operation still detected after gitops_clear_stale_operation" >&2
  fail=1
else
  echo "OK: gitops_clear_stale_operation correctly cleared it"
fi

if [ "$fail" -ne 0 ]; then
  echo "test-revision-switch: FAILED before switching back to main" >&2
  exit 1
fi

echo "test-revision-switch: step 6 - switching back to 'main'"
sh lab/gitops/switch-revision.sh main
final_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
final_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.targetRevision}')"
if [ "$final_uid" = "$baseline_uid" ]; then
  echo "OK: root Application UID unchanged throughout the full switch+switch-back ($final_uid)"
else
  echo "FAIL: root Application UID changed by the end of the test ($baseline_uid -> $final_uid)" >&2
  fail=1
fi
if [ "$final_rev" = "main" ]; then
  echo "OK: root Application is back at revision 'main'"
else
  echo "FAIL: root Application did not end at revision 'main' (got '$final_rev')" >&2
  fail=1
fi
pkubectl rollout status deployment/platform-smoke-staging-standard-workload -n staging --timeout=180s >/dev/null
pkubectl rollout status deployment/platform-smoke-production-standard-workload -n production --timeout=180s >/dev/null
echo "OK: staging and production workload Deployments are Available again on main"

if [ "$fail" -ne 0 ]; then
  echo "test-revision-switch: FAILED"
  exit 1
fi
echo "test-revision-switch: OK"
