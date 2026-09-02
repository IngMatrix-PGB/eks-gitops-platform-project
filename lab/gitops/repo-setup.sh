#!/bin/sh
# Idempotently provisions everything Argo CD needs to read this private
# repository over SSH: a project-local, checksum-tracked Ed25519 deploy
# key; a read-only GitHub deploy key attached to this exact repository;
# and the Argo CD repository-credential Secret referencing it. Never
# prints key or Secret contents. Backs `make gitops-repo-setup` (full
# idempotent setup) and, with GITOPS_CHECK_ONLY=1 set, `make
# gitops-repo-check` (read-only inspection, no mutation at all).
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

check_only="${GITOPS_CHECK_ONLY:-0}"

require_github_account
echo "OK: active gh account is $GITOPS_GITHUB_ACCOUNT"

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm

# --- 1. Local deploy key -------------------------------------------------
if gitops_deploy_key_present_locally; then
  echo "OK: local deploy key already present at $GITOPS_DEPLOY_KEY_PRIV (not regenerated - existing local key material is authoritative)"
else
  if [ "$check_only" = "1" ]; then
    echo "CHECK: local deploy key absent at $GITOPS_DEPLOY_KEY_PRIV"
  else
    mkdir -p "$GITOPS_DEPLOY_KEY_DIR"
    ssh-keygen -t ed25519 -f "$GITOPS_DEPLOY_KEY_PRIV" -N "" -C "$GITOPS_DEPLOY_KEY_TITLE" >/dev/null
    chmod 600 "$GITOPS_DEPLOY_KEY_PRIV"
    echo "OK: generated local Ed25519 deploy key at $GITOPS_DEPLOY_KEY_PRIV (mode 600)"
  fi
fi

if [ ! -f "$GITOPS_DEPLOY_KEY_PRIV" ]; then
  if [ "$check_only" = "1" ]; then
    echo "CHECK: cannot inspect further - no local key to compare against GitHub"
    exit 0
  fi
  echo "FAIL: local deploy key still absent after generation attempt" >&2
  exit 1
fi

actual_perm="$(stat -f '%Lp' "$GITOPS_DEPLOY_KEY_PRIV" 2>/dev/null || stat -c '%a' "$GITOPS_DEPLOY_KEY_PRIV" 2>/dev/null)"
if [ "$actual_perm" != "600" ]; then
  echo "FAIL: $GITOPS_DEPLOY_KEY_PRIV has mode $actual_perm, expected 600" >&2
  exit 1
fi
echo "OK: $GITOPS_DEPLOY_KEY_PRIV permissions are 600"

local_pub_content="$(awk '{print $1" "$2}' "$GITOPS_DEPLOY_KEY_PUB")"

# --- 2. GitHub deploy key -------------------------------------------------
matching_id="$(gh api "repos/${GITOPS_OWNER_REPO}/keys" --jq ".[] | select(.title==\"${GITOPS_DEPLOY_KEY_TITLE}\") | .id" 2>/dev/null | head -1)"

if [ -n "$matching_id" ]; then
  remote_key_body="$(gh api "repos/${GITOPS_OWNER_REPO}/keys/${matching_id}" --jq '.key' 2>/dev/null)"
  remote_key_short="$(printf '%s' "$remote_key_body" | awk '{print $1" "$2}')"
  if [ "$remote_key_short" != "$local_pub_content" ]; then
    echo "FAIL: a GitHub deploy key titled '$GITOPS_DEPLOY_KEY_TITLE' already exists (id $matching_id) with DIFFERENT key material than the local key - refusing to overwrite" >&2
    exit 1
  fi
  ro="$(gh api "repos/${GITOPS_OWNER_REPO}/keys/${matching_id}" --jq '.read_only')"
  if [ "$ro" != "true" ]; then
    echo "FAIL: GitHub deploy key id $matching_id ('$GITOPS_DEPLOY_KEY_TITLE') is NOT read-only" >&2
    exit 1
  fi
  echo "OK: GitHub deploy key '$GITOPS_DEPLOY_KEY_TITLE' already present (id $matching_id), matches local key, read-only confirmed"
else
  if [ "$check_only" = "1" ]; then
    echo "CHECK: GitHub deploy key '$GITOPS_DEPLOY_KEY_TITLE' absent"
  else
    new_id="$(gh api "repos/${GITOPS_OWNER_REPO}/keys" -f "title=${GITOPS_DEPLOY_KEY_TITLE}" -f "key=$(cat "$GITOPS_DEPLOY_KEY_PUB")" -F "read_only=true" --jq '.id' 2>&1)"
    new_ro="$(gh api "repos/${GITOPS_OWNER_REPO}/keys/${new_id}" --jq '.read_only' 2>/dev/null)"
    if [ "$new_ro" != "true" ]; then
      echo "FAIL: newly added deploy key (id ${new_id:-unknown}) did not come back read-only" >&2
      exit 1
    fi
    echo "OK: added read-only GitHub deploy key '$GITOPS_DEPLOY_KEY_TITLE' (id $new_id)"
  fi
fi

# --- 3. Argo CD known-hosts trust ------------------------------------------
if ! gitops_known_hosts_trust_github; then
  echo "FAIL: argocd-ssh-known-hosts-cm does not already trust github.com - refusing to mutate this Helm-managed ConfigMap" >&2
  echo "      (no ssh-keyscan trust-on-first-use is performed by this script)" >&2
  exit 1
fi
echo "OK: Argo CD's existing known-hosts configuration already trusts github.com"

# --- 4. Argo CD repository Secret ------------------------------------------
if gitops_repo_secret_exists; then
  if gitops_repo_secret_matches_local_key; then
    echo "OK: repository Secret '$GITOPS_REPO_SECRET_NAME' already present and matches the local key (sha256 + url) - no-op"
  else
    echo "FAIL: repository Secret '$GITOPS_REPO_SECRET_NAME' exists but does not match the local key/url - refusing to overwrite" >&2
    exit 1
  fi
else
  if [ "$check_only" = "1" ]; then
    echo "CHECK: repository Secret '$GITOPS_REPO_SECRET_NAME' absent"
  else
    priv_b64="$(base64 < "$GITOPS_DEPLOY_KEY_PRIV" | tr -d '\n')"
    url_b64="$(printf '%s' "$GITOPS_REPO_URL" | base64 | tr -d '\n')"
    type_b64="$(printf '%s' "git" | base64 | tr -d '\n')"
    cat <<EOF | pkubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: ${GITOPS_REPO_SECRET_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
    ${GITOPS_NS_OWNER_LABEL_KEY}: ${GITOPS_NS_OWNER_LABEL_VALUE}
data:
  type: ${type_b64}
  url: ${url_b64}
  sshPrivateKey: ${priv_b64}
EOF
    unset priv_b64
    echo "OK: created repository Secret '$GITOPS_REPO_SECRET_NAME' in namespace '$ARGOCD_NAMESPACE' (content not printed)"
  fi
fi

echo "gitops-repo-setup: OK"
