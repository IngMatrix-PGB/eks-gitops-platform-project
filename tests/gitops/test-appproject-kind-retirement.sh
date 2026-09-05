#!/bin/sh
# Mutating pre-merge test for Phase 2.6.3a's retire-appproject-kind.sh
# (Gap 3). Proves the full 8-step drain/resume sequence against
# staging's own live SecretStore/ExternalSecret/target Secret (the
# plan's actual, currently-deployed contract - never a synthetic
# stand-in). Restores staging to its pre-test Ready state at the end.
# Never prints a decoded secret value - every comparison is a SHA256
# hash, an ownerReference kind, or a status string. Backs
# `make gitops-test-appproject-kind-retirement` only.
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

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm
if ! argocd_release_exists; then
  echo "FAIL: Argo CD is not installed" >&2
  exit 1
fi

env_name="staging"
app="platform-smoke-staging"
secretstore_name="staging-kubernetes-backend"
externalsecret_name="platform-smoke-staging-standard-workload-secret"
target_secret_name="$externalsecret_name"
fail=0

if ! pkubectl get secretstore "$secretstore_name" -n "$env_name" >/dev/null 2>&1 \
  || ! pkubectl get externalsecret "$externalsecret_name" -n "$env_name" >/dev/null 2>&1 \
  || ! pkubectl get secret "$target_secret_name" -n "$env_name" >/dev/null 2>&1; then
  echo "FAIL: precondition failed - staging's SecretStore/ExternalSecret/target Secret must already exist and be Ready before this test runs" >&2
  exit 1
fi

echo "test-appproject-kind-retirement: step 0 - capture pre-test state"
pre_target_hash="$(pkubectl get secret "$target_secret_name" -n "$env_name" -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
echo "OK: pre-test target Secret hash captured ($pre_target_hash)"

whitelist_before="$(pkubectl get appproject platform -n "$ARGOCD_NAMESPACE" -o jsonpath='{.spec.namespaceResourceWhitelist}')"
if ! printf '%s' "$whitelist_before" | grep -q "SecretStore"; then
  echo "FAIL: precondition failed - AppProject does not currently whitelist SecretStore (step 2 of the drain requires it to)" >&2
  exit 1
fi
echo "OK: AppProject currently permits SecretStore/ExternalSecret (required before draining)"

echo "test-appproject-kind-retirement: running --drain ..."
sh lab/gitops/retire-appproject-kind.sh "$env_name" --drain

echo "test-appproject-kind-retirement: step 1 check - self-heal must remain paused after --drain"
if gitops_automated_sync_paused "$app"; then
  echo "OK: automated sync is paused on $app after --drain"
else
  echo "FAIL: automated sync should remain paused after --drain (self-heal must never resume until the whitelist change lands)" >&2
  fail=1
fi

echo "test-appproject-kind-retirement: step 3 check - SecretStore/ExternalSecret stably absent, zero orphans"
if pkubectl get secretstore "$secretstore_name" -n "$env_name" >/dev/null 2>&1; then
  echo "FAIL: SecretStore still exists after drain" >&2
  fail=1
else
  echo "OK: SecretStore absent"
fi
if pkubectl get externalsecret "$externalsecret_name" -n "$env_name" >/dev/null 2>&1; then
  echo "FAIL: ExternalSecret still exists after drain" >&2
  fail=1
else
  echo "OK: ExternalSecret absent"
fi

echo "test-appproject-kind-retirement: step 4 check - target Secret retained per creationPolicy: Owner / deletionPolicy: Retain"
if pkubectl get secret "$target_secret_name" -n "$env_name" >/dev/null 2>&1; then
  owner_kind="$(pkubectl get secret "$target_secret_name" -n "$env_name" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
  post_drain_hash="$(pkubectl get secret "$target_secret_name" -n "$env_name" -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
  if [ -n "$owner_kind" ]; then
    echo "FAIL: target Secret still has an owner ($owner_kind) after its ExternalSecret was deleted - Retain contract not honored" >&2
    fail=1
  elif [ "$post_drain_hash" != "$pre_target_hash" ]; then
    echo "FAIL: target Secret content changed during drain (hash $pre_target_hash -> $post_drain_hash) - it must only be retained, never modified" >&2
    fail=1
  else
    echo "OK: target Secret retained, orphaned, content unchanged (hash $post_drain_hash) - zero orphans, deletionPolicy=Retain honored"
  fi
else
  echo "FAIL: target Secret missing after drain - Retain contract violated" >&2
  fail=1
fi

echo "test-appproject-kind-retirement: step 5 check - no pending/Running operation on $app"
op_phase="$(pkubectl get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
if [ "$op_phase" = "Running" ]; then
  echo "FAIL: Application/$app still has a Running operation after drain" >&2
  fail=1
else
  echo "OK: no pending/Running operation on $app"
fi

echo "test-appproject-kind-retirement: this test never edits the AppProject (step 6 is a separate Git change per the plan) - proceeding straight to --resume to restore the pre-test contract"
sh lab/gitops/retire-appproject-kind.sh "$env_name" --resume

echo "test-appproject-kind-retirement: step 8 check - waiting for SecretStore/ExternalSecret to be recreated and reach Ready ..."
elapsed=0
ss_ready=""
es_ready=""
while [ "$elapsed" -lt 180 ]; do
  ss_ready="$(pkubectl get secretstore "$secretstore_name" -n "$env_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  es_ready="$(pkubectl get externalsecret "$externalsecret_name" -n "$env_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ss_ready" = "True" ] && [ "$es_ready" = "True" ] && break
  sleep 5
  elapsed=$((elapsed + 5))
done
if [ "$ss_ready" = "True" ] && [ "$es_ready" = "True" ]; then
  echo "OK: SecretStore/ExternalSecret Ready again after resume (within ${elapsed}s)"
else
  echo "FAIL: SecretStore/ExternalSecret did not become Ready again within 180s after resume (secretstore=$ss_ready externalsecret=$es_ready)" >&2
  fail=1
fi

if pkubectl get secret "$target_secret_name" -n "$env_name" >/dev/null 2>&1; then
  post_resume_hash="$(pkubectl get secret "$target_secret_name" -n "$env_name" -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
  if [ "$post_resume_hash" = "$pre_target_hash" ]; then
    echo "OK: target Secret hash unchanged end-to-end ($post_resume_hash) - zero orphans, zero content drift"
  else
    echo "FAIL: target Secret hash changed end-to-end ($pre_target_hash -> $post_resume_hash)" >&2
    fail=1
  fi
else
  echo "FAIL: target Secret missing after resume" >&2
  fail=1
fi

echo "test-appproject-kind-retirement: verifying AppProject whitelist is exactly unchanged (this test never edits it)"
whitelist_after="$(pkubectl get appproject platform -n "$ARGOCD_NAMESPACE" -o jsonpath='{.spec.namespaceResourceWhitelist}')"
if [ "$whitelist_after" = "$whitelist_before" ]; then
  echo "OK: AppProject namespaceResourceWhitelist is byte-for-byte unchanged"
else
  echo "FAIL: AppProject whitelist changed unexpectedly (before: $whitelist_before; after: $whitelist_after)" >&2
  fail=1
fi

if gitops_automated_sync_paused "$app"; then
  echo "FAIL: automated sync is still paused on $app after --resume" >&2
  fail=1
else
  echo "OK: automated sync is resumed (selfHeal+prune) on $app"
fi

if [ "$fail" -ne 0 ]; then
  echo "test-appproject-kind-retirement: FAILED"
  exit 1
fi
echo "test-appproject-kind-retirement: OK"
