#!/bin/sh
# Safely drains SecretStore/ExternalSecret from one environment's
# generated Application BEFORE those kinds are removed from the
# AppProject's namespaceResourceWhitelist (Phase 2.6.3a, Gap 3). This
# is deliberately NOT a generic resource-retirement tool: the only two
# kinds it ever touches are external-secrets.io/SecretStore and
# external-secrets.io/ExternalSecret, and the only two environments are
# staging and production - both fixed, not parameterizable.
#
# Implements the plan's 8-step order:
#   1. pause self-heal on the environment's generated Application (a
#      merge PATCH only - never deletes/recreates it)
#   2. delete the dependent SecretStore/ExternalSecret WHILE the
#      AppProject still permits them (this script never edits the
#      AppProject itself - narrowing the whitelist is a separate,
#      later Git change, per the plan)
#   3. wait for their stable absence (3 consecutive reads)
#   4. verify the target Secret per its ExternalSecret's own
#      deletionPolicy - never assumes garbage collection
#   5. confirm no pending/Running operation remains
#   (6. whitelist reduction is a Git change, NOT performed here)
#   7. `--resume` re-enables automated sync (a second invocation)
#   8. requires 3 consecutive stable reads before declaring success
#
# Every error path (drain mode) restores automated sync before exiting
# - self-heal is never left silently disabled on a failed drain.
#
# Usage:
#   sh lab/gitops/retire-appproject-kind.sh <staging|production> --drain
#   sh lab/gitops/retire-appproject-kind.sh <staging|production> --resume
#
# Exit codes:
#   0  drain (or resume) completed and is stable
#   1  usage/identity error - no mutation attempted
#   2  did not reach a stable state within timeout
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

env_name="${1:-}"
mode="${2:-}"

case "$env_name" in
  staging) app="platform-smoke-staging" ;;
  production) app="platform-smoke-production" ;;
  *)
    echo "FAIL: usage: sh lab/gitops/retire-appproject-kind.sh <staging|production> <--drain|--resume>" >&2
    exit 1
    ;;
esac

case "$mode" in
  --drain|--resume) : ;;
  *)
    echo "FAIL: usage: sh lab/gitops/retire-appproject-kind.sh <staging|production> <--drain|--resume>" >&2
    exit 1
    ;;
esac

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm
if ! argocd_release_exists; then
  echo "FAIL: Argo CD is not installed" >&2
  exit 1
fi
if ! gitops_generated_app_exists "$app"; then
  echo "FAIL: generated Application '$app' does not exist" >&2
  exit 1
fi

# The only two kinds this script ever touches - fixed, allowlisted, not
# a parameter.
secretstore_name="$(sed -n 's/^[[:space:]]*secretStoreName:[[:space:]]*"\([^"]*\)".*/\1/p' "charts/standard-workload/values-${env_name}.yaml")"
externalsecret_name="platform-smoke-${env_name}-standard-workload-secret"
target_secret_name="$externalsecret_name"
if [ -z "$secretstore_name" ]; then
  echo "FAIL: could not determine secretStoreName from charts/standard-workload/values-${env_name}.yaml" >&2
  exit 1
fi

retire_resumed_stable_predicate() {
  rrsp_status="$(pkubectl get application "$RETIRE_TARGET_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  [ "$rrsp_status" = "Synced/Healthy" ] || return 1
  rrsp_op="$(pkubectl get application "$RETIRE_TARGET_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.operationState.phase}' 2>/dev/null)"
  [ "$rrsp_op" = "Running" ] && return 1
  return 0
}

if [ "$mode" = "--resume" ]; then
  echo "retire-appproject-kind: step 7 - resuming automated sync on $app ..."
  gitops_resume_automated_sync "$app"
  pkubectl annotate application "$app" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  RETIRE_TARGET_APP="$app"
  echo "retire-appproject-kind: step 8 - waiting for 3 consecutive stable reads ..."
  if gitops_wait_stable retire_resumed_stable_predicate 3 15 300; then
    echo "OK: automated sync resumed - $app is Synced/Healthy across 3 stable reads"
    exit 0
  fi
  echo "FAIL: $app did not stabilize after resuming automated sync" >&2
  exit 2
fi

# --- --drain path ---

retire_absence_predicate() {
  pkubectl get secretstore "$RETIRE_SS" -n "$RETIRE_NS" >/dev/null 2>&1 && return 1
  pkubectl get externalsecret "$RETIRE_ES" -n "$RETIRE_NS" >/dev/null 2>&1 && return 1
  return 0
}

drain_left_paused=0
restore_unless_intentional() {
  if [ "$drain_left_paused" != "1" ]; then
    echo "retire-appproject-kind: restoring automated sync on $app before exiting (fail-safe - never leaves self-heal silently disabled) ..." >&2
    gitops_resume_automated_sync "$app" >/dev/null 2>&1 || true
  fi
}
trap restore_unless_intentional EXIT

echo "retire-appproject-kind: step 1 - pausing self-heal on $app (AppProject still permits SecretStore/ExternalSecret here) ..."
gitops_pause_automated_sync "$app"
if ! gitops_automated_sync_paused "$app"; then
  echo "FAIL: could not confirm automated sync is paused on $app" >&2
  exit 1
fi
echo "OK: automated sync paused on $app"

deletion_policy="$(pkubectl get externalsecret "$externalsecret_name" -n "$env_name" -o jsonpath='{.spec.target.deletionPolicy}' 2>/dev/null || true)"
echo "OK: captured ExternalSecret '$externalsecret_name' deletionPolicy='${deletion_policy:-<absent>}' before deletion"

echo "retire-appproject-kind: step 2 - deleting SecretStore/ExternalSecret in $env_name while still whitelisted ..."
pkubectl delete externalsecret "$externalsecret_name" -n "$env_name" --ignore-not-found
pkubectl delete secretstore "$secretstore_name" -n "$env_name" --ignore-not-found

RETIRE_NS="$env_name"; RETIRE_SS="$secretstore_name"; RETIRE_ES="$externalsecret_name"
echo "retire-appproject-kind: step 3 - waiting for stable absence (3 consecutive reads) ..."
if ! gitops_wait_stable retire_absence_predicate 3 15 300; then
  echo "FAIL: SecretStore/ExternalSecret did not reach stable absence in $env_name" >&2
  exit 2
fi
echo "OK: SecretStore/ExternalSecret stably absent in $env_name"

echo "retire-appproject-kind: step 4 - verifying target Secret per its deletionPolicy (metadata only, never content) ..."
if [ "$deletion_policy" = "Retain" ]; then
  if pkubectl get secret "$target_secret_name" -n "$env_name" >/dev/null 2>&1; then
    owner_kind="$(pkubectl get secret "$target_secret_name" -n "$env_name" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
    if [ -n "$owner_kind" ]; then
      echo "FAIL: target Secret '$target_secret_name' still references an owner ($owner_kind) after its ExternalSecret was deleted - Retain contract not honored" >&2
      exit 2
    fi
    echo "OK: target Secret '$target_secret_name' retained and orphaned (name/ownership checked, content never read) - deletionPolicy=Retain honored"
  else
    echo "FAIL: target Secret '$target_secret_name' is missing, but deletionPolicy=Retain requires it survive" >&2
    exit 2
  fi
else
  if pkubectl get secret "$target_secret_name" -n "$env_name" >/dev/null 2>&1; then
    echo "FAIL: target Secret '$target_secret_name' still exists but deletionPolicy='${deletion_policy:-<absent>}' (not Retain) expected it gone" >&2
    exit 2
  fi
  echo "OK: target Secret '$target_secret_name' garbage-collected, per deletionPolicy=${deletion_policy:-<absent>}"
fi

echo "retire-appproject-kind: step 5 - confirming no pending/Running operation on $app ..."
op_phase="$(pkubectl get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
if [ "$op_phase" = "Running" ]; then
  echo "FAIL: Application/$app still has a Running operation - refusing to declare drain complete" >&2
  exit 2
fi
echo "OK: no pending/Running operation on $app"

drain_left_paused=1
trap - EXIT
echo "retire-appproject-kind: drain complete for external-secrets.io/SecretStore and external-secrets.io/ExternalSecret in $env_name."
echo "retire-appproject-kind: self-heal is currently PAUSED on $app - intentional. Step 6 (reducing the AppProject whitelist) is a separate Git change; keep it paused until that change is merged and reconciled, then run:"
echo "  sh lab/gitops/retire-appproject-kind.sh $env_name --resume"
