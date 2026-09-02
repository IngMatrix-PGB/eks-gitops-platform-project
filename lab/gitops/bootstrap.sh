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

revision="${REVISION:-$GITOPS_DEFAULT_REVISION}"

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

if [ "$revision" = "$GITOPS_DEFAULT_REVISION" ]; then
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
