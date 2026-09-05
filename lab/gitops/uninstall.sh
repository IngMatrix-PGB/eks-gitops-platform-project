#!/bin/sh
# Two-phase transactional uninstall (Phase 2.6.3a). Phase A (preflight)
# is strictly read-only: it classifies every namespaced object in
# staging/production BEFORE the root Application is touched, and
# aborts with ZERO mutation if anything is unclassifiable. Phase B
# (execution) only begins once Phase A has fully passed.
#
# Preserves Argo CD itself, its CRDs, the repository Secret, and the
# deploy key - none of those are touched here. Idempotent. Backs
# `make gitops-uninstall`.
#
# Root cause this replaces (see
# .local/evidence/phase-2.6.3-gitops-lifecycle-hardening-plan.md, Gap
# 1): the previous single-phase version deleted the root Application
# first (cascading through AppProject/ApplicationSet/generated
# Applications/their managed resources) and only checked namespace
# contents afterward - by then, ESO's Phase 2.6.1 scoped-RBAC
# Role/RoleBinding objects (which legitimately live inside
# staging/production, not just eso-staging/eso-production) always made
# that check refuse to delete the namespace, but the workloads were
# already gone. Reproduced and recovered once during Phase 2.6.2
# testing.
#
# Exit codes:
#   0  nothing to do, or fully uninstalled successfully
#   1  Phase A preflight blocked (an unclassifiable/unknown object, or
#      ESO reported unhealthy) - zero mutation performed
#   2  Phase B execution hit a retryable condition (e.g. the root
#      Application delete timed out) - safe to re-run, idempotent
#   3  Phase B execution hit an unexpected post-condition that should
#      be unreachable given a passing Phase A - fail loud rather than
#      silently accept
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
# shellcheck source=../../scripts/eso/_lib.sh
. scripts/eso/_lib.sh
# shellcheck source=../../scripts/gitops/_lib.sh
. scripts/gitops/_lib.sh

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

if ! gitops_root_app_exists; then
  echo "OK: root Application '$GITOPS_ROOT_APP_NAME' already absent"
  exit 0
fi

# ============================================================
# Phase A - preflight (strictly read-only, zero mutation)
# ============================================================
echo "gitops-uninstall: Phase A - preflight (read-only) ..."

pre_uid="$(gitops_app_uid "$GITOPS_ROOT_APP_NAME")"
pre_generation="$(gitops_app_generation "$GITOPS_ROOT_APP_NAME")"
echo "OK: captured pre-preflight root Application state (uid=$pre_uid generation=$pre_generation)"

preflight_fail=0
staging_decision="absent"
production_decision="absent"

classify_and_decide_namespace() {
  # Prints exactly one of: absent | delete | retain_eso_active |
  # retain_eso_residual | UNCLASSIFIABLE (all diagnostic output goes to
  # stderr - only the decision word itself goes to stdout, since the
  # caller captures it via command substitution).
  cadn_ns="$1"; cadn_app="$2"

  if ! pkubectl get namespace "$cadn_ns" >/dev/null 2>&1; then
    echo "OK: namespace '$cadn_ns' does not exist - nothing to classify" >&2
    echo "absent"
    return 0
  fi

  cadn_class_file="$(mktemp)" || { echo "UNCLASSIFIABLE"; return 0; }
  if ! gitops_classify_namespace "$cadn_ns" "$cadn_app" "$cadn_class_file"; then
    echo "FAIL: could not classify namespace '$cadn_ns' (discovery error)" >&2
    rm -f "$cadn_class_file"
    echo "UNCLASSIFIABLE"
    return 0
  fi

  cadn_unknown="$(grep '^unknown ' "$cadn_class_file" || true)"
  if [ -n "$cadn_unknown" ]; then
    cadn_count="$(printf '%s\n' "$cadn_unknown" | wc -l | tr -d ' ')"
    echo "FAIL: namespace '$cadn_ns' has $cadn_count unclassified (unknown) object(s):" >&2
    printf '%s\n' "$cadn_unknown" >&2
    rm -f "$cadn_class_file"
    echo "UNCLASSIFIABLE"
    return 0
  fi

  if eso_scoped_namespace_active "$cadn_ns"; then
    echo "NOTE: namespace '$cadn_ns' - an active ESO scoped release still targets it - will RETAIN" >&2
    rm -f "$cadn_class_file"
    echo "retain_eso_active"
    return 0
  fi

  if grep -q '^helm-eso-scoped ' "$cadn_class_file"; then
    echo "NOTE: namespace '$cadn_ns' - residual Helm/ESO-owned object(s) present with no active release - will RETAIN" >&2
    rm -f "$cadn_class_file"
    echo "retain_eso_residual"
    return 0
  fi

  echo "OK: namespace '$cadn_ns' - fully classified (argocd-tracked/kubernetes-builtin only) - eligible for deletion" >&2
  rm -f "$cadn_class_file"
  echo "delete"
}

staging_decision="$(classify_and_decide_namespace staging platform-smoke-staging)"
[ "$staging_decision" = "UNCLASSIFIABLE" ] && preflight_fail=1
production_decision="$(classify_and_decide_namespace production platform-smoke-production)"
[ "$production_decision" = "UNCLASSIFIABLE" ] && preflight_fail=1

# ESO health is only a gate when ESO is actually installed - this
# script must remain safe to run on a cluster that has never had ESO
# (Phase 2.3-era state), matching tests/gitops/test-lifecycle.sh's own
# from-scratch precondition.
eso_any_installed=0
while IFS='|' read -r env_name eso_ns eso_release wc cc; do
  [ -z "$env_name" ] && continue
  if eso_release_exists "$eso_ns" "$eso_release"; then
    eso_any_installed=1
  fi
done <<EOF
$(eso_environments)
EOF

if [ "$eso_any_installed" -eq 1 ]; then
  eso_health_out="$(mktemp)"
  if ! sh tests/eso/test-runtime-health.sh >"$eso_health_out" 2>&1; then
    echo "FAIL: ESO health check failed - refusing to proceed:" >&2
    cat "$eso_health_out" >&2
    rm -f "$eso_health_out"
    preflight_fail=1
  else
    echo "OK: ESO health check passed"
    rm -f "$eso_health_out"
  fi
else
  echo "OK: ESO is not installed - nothing to check"
fi

if [ "$preflight_fail" -ne 0 ]; then
  echo "gitops-uninstall: Phase A FAILED - zero mutation performed, root Application untouched" >&2
  exit 1
fi
echo "OK: Phase A preflight passed (staging=$staging_decision production=$production_decision)"

# ============================================================
# Phase B - execution (only reached if Phase A passed)
# ============================================================
echo "gitops-uninstall: Phase B - execution ..."
echo "gitops-uninstall: deleting root Application '$GITOPS_ROOT_APP_NAME' (foreground cascade via finalizer) ..."
# Observed empirically: the root's own finalizer deletes its two
# rendered children (AppProject, ApplicationSet) without an ordering
# guarantee between them. If the AppProject disappears first, the
# ApplicationSet's already-generated Applications briefly fail to
# resolve their project reference; the application-controller's next
# resync (informer-cache-bound, observed up to ~2-3 minutes even on a
# healthy chain) retries and completes the delete correctly on its
# own - never a real deadlock, just slower than a short timeout
# suggests. 300s comfortably covers that, without ever force-removing
# a finalizer.
if ! pkubectl -n "$ARGOCD_NAMESPACE" delete application "$GITOPS_ROOT_APP_NAME" --wait --timeout=300s; then
  echo "FAIL: root Application delete timed out - safe to re-run (idempotent)" >&2
  exit 2
fi
echo "OK: root Application deleted (cascade removed AppProject/ApplicationSet/generated Applications/ConfigMaps)"

cascade_fail=0
if gitops_appproject_exists; then
  echo "FAIL: AppProject '$GITOPS_PROJECT_NAME' still present after root Application deletion" >&2
  cascade_fail=1
fi
if gitops_appset_exists; then
  echo "FAIL: ApplicationSet '$GITOPS_APPSET_NAME' still present after root Application deletion" >&2
  cascade_fail=1
fi
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    echo "FAIL: generated Application '$app' still present after root Application deletion" >&2
    cascade_fail=1
  fi
done
if [ "$cascade_fail" -ne 0 ]; then
  echo "gitops-uninstall: FAILED post-cascade check - this should be unreachable given a passing Phase A" >&2
  exit 3
fi
echo "OK: AppProject, ApplicationSet, and both generated Applications are gone"

for ns in staging production; do
  decision=""
  case "$ns" in
    staging) decision="$staging_decision" ;;
    production) decision="$production_decision" ;;
  esac
  case "$decision" in
    absent)
      echo "OK: namespace '$ns' already absent - nothing to do"
      ;;
    delete)
      escaped_owner_key="$(printf '%s' "$GITOPS_NS_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
      owner_label="$(pkubectl get namespace "$ns" -o jsonpath="{.metadata.labels.${escaped_owner_key}}" 2>/dev/null || true)"
      if [ "$owner_label" != "$GITOPS_NS_OWNER_LABEL_VALUE" ]; then
        echo "FAIL: namespace '$ns' ownership label changed between Phase A and Phase B - refusing to delete" >&2
        exit 3
      fi
      pkubectl delete namespace "$ns"
      echo "OK: namespace '$ns' deleted (Phase A classified it fully GitOps-owned - argocd-tracked/kubernetes-builtin only)"
      ;;
    retain_eso_active)
      echo "OK: namespace '$ns' RETAINED - an active ESO scoped release still targets it. Run 'make eso-uninstall' first if you also want this namespace removed."
      ;;
    retain_eso_residual)
      echo "OK: namespace '$ns' RETAINED - residual Helm/ESO-owned RBAC present with no active release. Clean up manually (helm uninstall / kubectl delete) if desired."
      ;;
    *)
      echo "FAIL: namespace '$ns' has no recorded Phase A decision - refusing to touch it" >&2
      exit 3
      ;;
  esac
done

echo "gitops-uninstall: OK"
