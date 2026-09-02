#!/bin/sh
# Removes exactly the three things repo-setup.sh created: the Argo CD
# repository Secret, the GitHub deploy key (by exact id/title match
# only), and the local .local/gitops key files. Requires an explicit
# confirmation variable - never runs as part of the normal lifecycle
# test and is never invoked by the final-installation path. Backs
# `make gitops-repo-remove` only.
set -eu

if [ "${CONFIRM:-}" != "REMOVE" ]; then
  echo "FAIL: refusing to remove GitOps repository authentication without explicit confirmation" >&2
  echo "      re-run as: CONFIRM=REMOVE make gitops-repo-remove" >&2
  exit 1
fi

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

require_github_account

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

if gitops_repo_secret_exists; then
  pkubectl -n "$ARGOCD_NAMESPACE" delete secret "$GITOPS_REPO_SECRET_NAME"
  echo "OK: removed repository Secret '$GITOPS_REPO_SECRET_NAME'"
else
  echo "OK: repository Secret '$GITOPS_REPO_SECRET_NAME' already absent"
fi

matching_id="$(gh api "repos/${GITOPS_OWNER_REPO}/keys" --jq ".[] | select(.title==\"${GITOPS_DEPLOY_KEY_TITLE}\") | .id" 2>/dev/null | head -1)"
if [ -n "$matching_id" ]; then
  gh api -X DELETE "repos/${GITOPS_OWNER_REPO}/keys/${matching_id}" >/dev/null
  echo "OK: removed GitHub deploy key '$GITOPS_DEPLOY_KEY_TITLE' (id $matching_id)"
else
  echo "OK: GitHub deploy key '$GITOPS_DEPLOY_KEY_TITLE' already absent"
fi

if [ -f "$GITOPS_DEPLOY_KEY_PRIV" ] || [ -f "$GITOPS_DEPLOY_KEY_PUB" ]; then
  rm -f "$GITOPS_DEPLOY_KEY_PRIV" "$GITOPS_DEPLOY_KEY_PUB"
  echo "OK: removed local key files ($GITOPS_DEPLOY_KEY_PRIV, $GITOPS_DEPLOY_KEY_PUB)"
else
  echo "OK: local key files already absent"
fi

echo "gitops-repo-remove: OK"
