#!/bin/sh
# Fail-closed, idempotent applier for the root Application only -
# everything else (AppProject, ApplicationSet, generated Applications,
# namespaces, ConfigMaps) is reconciled by Argo CD from Git afterward.
#   absent      -> apply
#   exact match -> true no-op (never calls kubectl apply)
#   drift       -> fails closed, no automatic reconciliation
# Accepts REVISION=<value> (default main): renders a temporary root
# manifest for a non-default revision under .local/gitops/ and applies
# that instead - the committed gitops/root-application.yaml is never
# edited. Backs `make gitops-bootstrap`.
#
# Phase 3.3.4b: also accepts PROFILE=local-kind|aws-eks (default
# local-kind - every existing invocation of this script, with no
# PROFILE set, takes the exact same branch as before this parameter
# existed, byte-for-byte unchanged messages/exit codes). "aws-eks" is
# DESIGNED / NOT DEPLOYED / NOT VALIDATED AGAINST AWS - ACTUAL COST:
# USD 0. It runs the fail-closed EKS identity preflight
# (check_eks_cluster_identity(), scripts/lab/_lib.sh) and computes a
# non-secret fingerprint, then stops deliberately - this script does
# not yet apply any Application for aws-eks (no root-application-aws-
# eks.yaml exists to apply, and none is created by this phase). Any
# other PROFILE value fails closed immediately.
#
# Phase 2.7.4: PROFILE now defaults to the target cluster's own profile
# (local-kind on lab-lite, unchanged; local-multicluster on the
# lab-multicluster hub - see scripts/gitops/_lib.sh GITOPS_PROFILE).
# local-multicluster also requires every registered spoke to be running
# with its ESO release Available and its source Secret present.
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

profile="${PROFILE:-$GITOPS_PROFILE}"

case "$profile" in

local-kind|local-multicluster)

revision="${REVISION:-$GITOPS_DEFAULT_REVISION}"

# Phase 2.7.4: the local profile is bound to the target cluster
# (scripts/gitops/_lib.sh GITOPS_PROFILE) - local-multicluster only on
# the lab-multicluster hub, local-kind everywhere else; a spoke never
# runs the bootstrap. A mismatch would put workloads on the hub or try
# to reach spokes from a cluster that has none, so it fails closed.
case "${LAB_CLUSTER:-lab-lite}" in
  dev|uat|prod)
    echo "FAIL: the GitOps bootstrap runs on the hub (LAB_CLUSTER=hub), never on spoke '$LAB_CLUSTER'" >&2
    exit 1
    ;;
esac
if [ "$profile" != "$GITOPS_PROFILE" ]; then
  echo "FAIL: PROFILE '$profile' does not match cluster '${LAB_CLUSTER:-lab-lite}' (expected '$GITOPS_PROFILE')" >&2
  exit 1
fi

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm
if ! argocd_release_exists; then
  echo "FAIL: Argo CD is not installed - run 'make argocd-install' first" >&2
  exit 1
fi

repo_check_out="$(mktemp)"
trap 'rm -f "$repo_check_out"' EXIT INT TERM
repo_check_rc=0
GITOPS_CHECK_ONLY=1 sh lab/gitops/repo-setup.sh >"$repo_check_out" 2>&1 || repo_check_rc=$?
if [ "$repo_check_rc" -ne 0 ] || grep -q '^CHECK:' "$repo_check_out"; then
  echo "FAIL: repository authentication is not fully provisioned - run 'make gitops-repo-setup' first" >&2
  cat "$repo_check_out" >&2
  exit 1
fi
echo "OK: repository authentication already provisioned"

echo "gitops-bootstrap: verifying remote revision '${revision}' exists ..."
if ! gitops_remote_revision_exists "$revision"; then
  echo "FAIL: remote revision '${revision}' does not exist on ${GITOPS_REPO_URL} (verified via the project's own deploy key)" >&2
  exit 1
fi
echo "OK: remote revision '${revision}' exists"

if [ "$profile" = "local-multicluster" ]; then
  # shellcheck source=../multicluster/_lib.sh
  . lab/multicluster/_lib.sh
  mc_apps="$(gitops_generated_apps)"
  if [ -z "$mc_apps" ]; then
    echo "FAIL: no spoke is registered on the hub - run 'make mc-spoke-register SPOKE=<env>' first" >&2
    exit 1
  fi
  for mc_app in $mc_apps; do
    mc_env="${mc_app#platform-smoke-}"
    if ! lab_mc_identity "$mc_env"; then
      echo "FAIL: spoke '$mc_env' is registered on the hub but its cluster is not running ($LAB_MC_IDENTITY_CASE)" >&2
      exit 1
    fi
    if ! mc_reason="$(lab_mc_spoke_ready "$mc_env")"; then
      echo "FAIL: $mc_reason" >&2
      exit 1
    fi
    echo "OK: spoke '$mc_env' registered, running, ESO Available and source Secret present"
  done
fi

if [ "$revision" = "$GITOPS_DEFAULT_REVISION" ] && [ "$profile" = "local-kind" ]; then
  apply_file="$GITOPS_ROOT_APP_FILE"
else
  apply_file="$(gitops_render_root_app_for_revision "$revision")"
  echo "OK: rendered temporary root manifest for revision '${revision}' at $apply_file (committed file untouched)"
fi

desired_fp="$(gitops_root_app_desired_fingerprint "$revision")"

if gitops_root_app_exists; then
  live_fp="$(gitops_root_app_live_fingerprint)"
  if [ "$desired_fp" = "$live_fp" ]; then
    echo "OK: root Application '$GITOPS_ROOT_APP_NAME' already matches exactly (revision ${revision}) - true no-op"
    exit 0
  fi
  echo "FAIL: root Application '$GITOPS_ROOT_APP_NAME' exists but drifted from the desired spec - refusing to reconcile automatically" >&2
  echo "      desired: $desired_fp" >&2
  echo "      live:    $live_fp" >&2
  exit 1
fi

echo "gitops-bootstrap: root Application absent - applying (revision ${revision}) ..."
pkubectl apply -f "$apply_file"

live_fp="$(gitops_root_app_live_fingerprint)"
if [ "$live_fp" != "$desired_fp" ]; then
  echo "FAIL: post-apply verification did not match the desired spec" >&2
  echo "      desired: $desired_fp" >&2
  echo "      live:    $live_fp" >&2
  exit 1
fi

echo "OK: root Application '$GITOPS_ROOT_APP_NAME' applied and verified"
echo "gitops-bootstrap: OK"
;;

aws-eks)

# Every fact below is an explicit, required parameter - never a
# default baked into Git, never a fallback to $PROJECT_KUBECONFIG or
# any ambient kubeconfig/context. See docs/runbooks/eks-bootstrap-
# order.md and docs/adr/0014-eks-application-identity-boundary.md.
eks_kubeconfig="${EKS_KUBECONFIG:-}"
eks_context="${EKS_CONTEXT:-}"
eks_cluster_name="${EKS_CLUSTER_NAME:-}"
eks_region="${EKS_REGION:-}"
eks_endpoint="${EKS_ENDPOINT:-}"
revision="${REVISION:-}"

echo "gitops-bootstrap: profile=aws-eks (DESIGNED / NOT DEPLOYED / NOT VALIDATED AGAINST AWS - ACTUAL COST: USD 0). Running identity preflight only - this profile never applies anything yet."

if ! check_eks_cluster_identity "$profile" "$eks_kubeconfig" "$eks_context" "$eks_cluster_name" "$eks_region" "$eks_endpoint" "$revision" "$GITOPS_REPO_URL"; then
  echo "FAIL: aws-eks identity preflight rejected ($EKS_IDENTITY_CASE): $EKS_IDENTITY_DETAIL" >&2
  exit 1
fi
echo "OK: aws-eks identity preflight passed - $EKS_IDENTITY_DETAIL"

eks_fp="$(eks_identity_fingerprint "$profile" "$eks_context" "$eks_cluster_name" "$eks_region" "$eks_endpoint" "$revision" "$GITOPS_REPO_URL")"
echo "OK: identity fingerprint (non-secret - profile/context/cluster/region/endpoint/revision/repoURL only): $eks_fp"

echo "gitops-bootstrap: aws-eks preflight complete. Stopping here by design - no root-application-aws-eks.yaml exists to apply, and this phase (Phase 3.3.4b/3.3.5, EKS identity boundary only) authorizes no mutation against any EKS cluster. A future, separately authorized phase defines the actual apply step, per docs/runbooks/eks-bootstrap-order.md."
;;

*)
echo "FAIL: unknown PROFILE '$profile' - must be exactly 'local-kind', 'local-multicluster' or 'aws-eks'" >&2
exit 1
;;

esac
