#!/bin/sh
# Safely switches the root Application's targetRevision IN PLACE - a
# plain `kubectl apply` (server-side patch), NEVER a delete+recreate
# (Phase 2.6.3a, Gap 2). Preserves .metadata.uid and
# .metadata.finalizers across the switch (verified, not assumed);
# requires at least 3 consecutive stable reads of revision+Synced+
# Healthy+no-active-operation+zero-OutOfSync before declaring success;
# detects and remediates a stale queued self-heal operation left over
# from a prior switch; rolls back to the ORIGINAL revision, in place,
# if convergence is not reached within the timeout.
#
# lab/gitops/bootstrap.sh is deliberately fail-closed on any revision
# change (it cannot distinguish an intentional switch from accidental
# drift) - this script is the first-class, safe alternative to the
# previous only options ("refuse" or "delete everything and rebuild
# via lab/gitops/uninstall.sh + bootstrap.sh", which Gap 1 showed can
# destroy running workloads on a cluster where ESO is also installed).
#
# Usage:
#   REVISION=<value> sh lab/gitops/switch-revision.sh
#   sh lab/gitops/switch-revision.sh <value>
#
# Exit codes:
#   0  switched and converged (or already at that revision - no-op)
#   1  requested revision does not exist upstream, or a usage/identity
#      error - no mutation attempted
#   2  switched but did not converge within timeout; automatic
#      rollback to the original revision ALSO failed - cluster may be
#      mid-transition, manual investigation required (no secret
#      evidence is ever printed)
#   3  switched but did not converge; automatic rollback to the
#      original revision succeeded and re-converged - the requested
#      switch is a reported failure, but the cluster is back in its
#      prior, healthy state
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

new_revision="${1:-${REVISION:-}}"
if [ -z "$new_revision" ]; then
  echo "FAIL: usage: REVISION=<value> sh lab/gitops/switch-revision.sh  (or pass it as \$1)" >&2
  exit 1
fi

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
  echo "FAIL: root Application '$GITOPS_ROOT_APP_NAME' does not exist - use 'make gitops-bootstrap' for a first install" >&2
  exit 1
fi

if ! gitops_remote_revision_exists "$new_revision"; then
  echo "FAIL: revision '$new_revision' does not exist on $GITOPS_REPO_URL" >&2
  exit 1
fi
echo "OK: revision '$new_revision' exists on the remote"

old_revision="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.targetRevision}')"
if [ "$old_revision" = "$new_revision" ]; then
  echo "OK: root Application already at revision '$new_revision' - true no-op"
  exit 0
fi

pre_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
pre_finalizers="$(gitops_app_finalizers "$GITOPS_ROOT_APP_NAME")"
pre_generation="$(gitops_app_generation "$GITOPS_ROOT_APP_NAME")"
echo "switch-revision: pre-switch state captured (revision=$old_revision uid=$pre_uid generation=$pre_generation)"

apply_revision() {
  sr_rev="$1"
  sr_file="$(gitops_render_root_app_for_revision "$sr_rev")"
  pkubectl apply -f "$sr_file"
}

# Predicate for gitops_wait_stable: reads $SWITCH_REVISION_TARGET
# (module-global, set right before each call) rather than taking an
# argument - POSIX sh predicates called by gitops_wait_stable take no
# arguments.
switch_stable_predicate() {
  ssp_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null)"
  [ "$ssp_rev" = "$SWITCH_REVISION_TARGET" ] || return 1
  ssp_sync="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null)"
  [ "$ssp_sync" = "Synced" ] || return 1
  ssp_health="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null)"
  [ "$ssp_health" = "Healthy" ] || return 1
  ssp_op="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.status.operationState.phase}' 2>/dev/null)"
  [ "$ssp_op" = "Running" ] && return 1
  ssp_oos="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.status.resources[?(@.status=="OutOfSync")]}' 2>/dev/null)"
  [ -z "$ssp_oos" ] || return 1
  for ssp_app in $GITOPS_GENERATED_APPS; do
    ssp_child="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$ssp_app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
    [ "$ssp_child" = "Synced/Healthy" ] || return 1
  done
  return 0
}

echo "switch-revision: applying revision '$new_revision' in place (patch, never delete) ..."
apply_revision "$new_revision"
pkubectl annotate application "$GITOPS_ROOT_APP_NAME" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

post_apply_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
if [ "$post_apply_uid" != "$pre_uid" ]; then
  echo "FAIL: root Application UID changed ($pre_uid -> $post_apply_uid) - something deleted and recreated it outside this script's control" >&2
  exit 2
fi
echo "OK: root Application UID unchanged after apply ($post_apply_uid) - confirmed patch, not delete+recreate"

SWITCH_REVISION_TARGET="$new_revision"
if gitops_detect_stale_operation "$GITOPS_ROOT_APP_NAME"; then
  echo "switch-revision: stale queued operation detected on root Application - clearing (self-heal will re-queue correctly)"
  gitops_clear_stale_operation "$GITOPS_ROOT_APP_NAME"
fi
for app in $GITOPS_GENERATED_APPS; do
  if gitops_detect_stale_operation "$app"; then
    echo "switch-revision: stale queued operation detected on $app - clearing"
    gitops_clear_stale_operation "$app"
  fi
done

echo "switch-revision: waiting for convergence (3 consecutive stable reads) ..."
if gitops_wait_stable switch_stable_predicate 3 15 420; then
  post_finalizers="$(gitops_app_finalizers "$GITOPS_ROOT_APP_NAME")"
  post_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
  if [ "$post_uid" != "$pre_uid" ] || [ "$post_finalizers" != "$pre_finalizers" ]; then
    echo "FAIL: UID or finalizers changed across the switch (uid: $pre_uid -> $post_uid; finalizers: $pre_finalizers -> $post_finalizers)" >&2
    exit 2
  fi
  echo "OK: switched to revision '$new_revision' - UID and finalizers unchanged, 3 consecutive stable reads confirmed"
  exit 0
fi

echo "FAIL: did not converge on revision '$new_revision' within timeout - rolling back to '$old_revision'" >&2
apply_revision "$old_revision"
pkubectl annotate application "$GITOPS_ROOT_APP_NAME" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
SWITCH_REVISION_TARGET="$old_revision"
if gitops_detect_stale_operation "$GITOPS_ROOT_APP_NAME"; then
  gitops_clear_stale_operation "$GITOPS_ROOT_APP_NAME"
fi
if gitops_wait_stable switch_stable_predicate 3 15 420; then
  echo "FAIL: revision '$new_revision' did not converge; automatic rollback to '$old_revision' succeeded and re-converged" >&2
  exit 3
fi
echo "FAIL: revision '$new_revision' did not converge, AND rollback to '$old_revision' also did not converge - cluster state requires manual investigation (no secret evidence printed)" >&2
exit 2
