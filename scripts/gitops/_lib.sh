#!/bin/sh
# Shared constants and helpers for lab/gitops/*.sh and tests/gitops/*.sh.
# POSIX-compatible shell only. Sourced, never executed directly. Assumes
# the caller's working directory is the repository root, and that
# scripts/lab/_lib.sh (project cluster/kubeconfig constants, pkubectl)
# and scripts/argocd/_lib.sh (phelm, ARGOCD_NAMESPACE) have already been
# sourced first.

GITOPS_GITHUB_ACCOUNT="IngMatrix-PGB"
GITOPS_OWNER_REPO="IngMatrix-PGB/eks-gitops-platform-project"
GITOPS_REPO_URL="git@github.com:IngMatrix-PGB/eks-gitops-platform-project.git"
GITOPS_DEPLOY_KEY_TITLE="eks-gitops-lab-lite-argocd"
GITOPS_DEPLOY_KEY_DIR=".local/gitops"
GITOPS_DEPLOY_KEY_PRIV=".local/gitops/github-deploy-key"
GITOPS_DEPLOY_KEY_PUB=".local/gitops/github-deploy-key.pub"
GITOPS_REPO_SECRET_NAME="eks-gitops-platform-project-repo"
GITOPS_NS_OWNER_LABEL_KEY="eks-gitops-lab-lite.local/owner"
GITOPS_NS_OWNER_LABEL_VALUE="gitops-bootstrap"
GITOPS_PROJECT_NAME="platform"
GITOPS_APPSET_NAME="platform-environments"
GITOPS_ROOT_APP_NAME="platform-bootstrap"
GITOPS_ROOT_APP_FILE="gitops/root-application.yaml"
GITOPS_CHART_PATH="gitops/bootstrap"
GITOPS_DEFAULT_REVISION="main"
GITOPS_GENERATED_APPS="platform-smoke-staging platform-smoke-production"

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "FAIL: gh (GitHub CLI) not found in PATH" >&2
    exit 1
  fi
}

# Fails closed rather than switching accounts automatically: the active
# gh account controls what a deploy key gets attached to, so silently
# switching it here would make deploy-key ownership ambiguous - exactly
# the condition this project's own authorization requires stopping for.
require_github_account() {
  require_gh
  active="$(gh api user --jq .login 2>/dev/null)" || active=""
  if [ "$active" != "$GITOPS_GITHUB_ACCOUNT" ]; then
    echo "FAIL: active gh account is '${active:-<none>}', expected '$GITOPS_GITHUB_ACCOUNT'" >&2
    echo "      run: gh auth switch -u $GITOPS_GITHUB_ACCOUNT" >&2
    exit 1
  fi
}

gitops_repo_secret_exists() {
  pkubectl -n "$ARGOCD_NAMESPACE" get secret "$GITOPS_REPO_SECRET_NAME" >/dev/null 2>&1
}

gitops_deploy_key_present_locally() {
  [ -f "$GITOPS_DEPLOY_KEY_PRIV" ] && [ -f "$GITOPS_DEPLOY_KEY_PUB" ]
}

# git ls-remote using ONLY the project's own deploy key - never the
# operator's personal SSH identity or agent.
gitops_git_ssh() {
  GIT_SSH_COMMAND="ssh -i $(pwd)/${GITOPS_DEPLOY_KEY_PRIV} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -F /dev/null" \
    git "$@"
}

gitops_remote_revision_exists() {
  rev="$1"
  gitops_git_ssh ls-remote --exit-code "$GITOPS_REPO_URL" "$rev" >/dev/null 2>&1 \
    || gitops_git_ssh ls-remote --exit-code "$GITOPS_REPO_URL" "refs/heads/$rev" >/dev/null 2>&1
}

# argocd-ssh-known-hosts-cm is Helm-managed (argo-helm chart default,
# already includes github.com's real host keys). This only ever reads
# it - never writes, never runs ssh-keyscan, never trust-on-first-use.
gitops_known_hosts_trust_github() {
  pkubectl -n "$ARGOCD_NAMESPACE" get configmap argocd-ssh-known-hosts-cm \
    -o jsonpath='{.data.ssh_known_hosts}' 2>/dev/null | grep -qE '^github\.com '
}

# Non-secret identity check: SHA256 of key material and the (non-secret)
# URL field only - never prints or returns the private key content.
gitops_repo_secret_matches_local_key() {
  [ -f "$GITOPS_DEPLOY_KEY_PRIV" ] || return 1
  local_sha="$(shasum -a 256 "$GITOPS_DEPLOY_KEY_PRIV" | awk '{print $1}')"
  live_key_b64="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "$GITOPS_REPO_SECRET_NAME" -o jsonpath='{.data.sshPrivateKey}' 2>/dev/null)"
  [ -n "$live_key_b64" ] || return 1
  live_sha="$(printf '%s' "$live_key_b64" | base64 -D 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  live_url="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "$GITOPS_REPO_SECRET_NAME" -o jsonpath='{.data.url}' 2>/dev/null | base64 -D 2>/dev/null)"
  [ "$local_sha" = "$live_sha" ] && [ "$live_url" = "$GITOPS_REPO_URL" ]
}

# Renders a temporary root-application manifest with targetRevision and
# the gitRevision Helm parameter both overridden to $1, without ever
# editing the committed GITOPS_ROOT_APP_FILE. Prints the temp file path.
gitops_render_root_app_for_revision() {
  rev="$1"
  mkdir -p "$GITOPS_DEPLOY_KEY_DIR"
  out="${GITOPS_DEPLOY_KEY_DIR}/root-application.${rev##*/}.yaml"
  sed -e "s#targetRevision: ${GITOPS_DEFAULT_REVISION}#targetRevision: ${rev}#" \
      -e "s#value: ${GITOPS_DEFAULT_REVISION}#value: ${rev}#" \
      "$GITOPS_ROOT_APP_FILE" > "$out"
  printf '%s\n' "$out"
}

# Fingerprint of the fields that matter for true no-op detection - never
# a full-object compare (server-set fields like resourceVersion/status
# would always differ).
gitops_root_app_desired_fingerprint() {
  rev="$1"
  printf 'repoURL=%s|targetRevision=%s|path=%s|helmGitRevision=%s|destNamespace=%s|automated=selfHeal:true,prune:true' \
    "$GITOPS_REPO_URL" "$rev" "$GITOPS_CHART_PATH" "$rev" "$ARGOCD_NAMESPACE"
}

gitops_root_app_live_fingerprint() {
  live_repo="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)"
  live_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null)"
  live_path="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.path}' 2>/dev/null)"
  live_helm_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.source.helm.parameters[?(@.name=="gitRevision")].value}' 2>/dev/null)"
  live_dest_ns="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)"
  live_selfheal="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null)"
  live_prune="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" -o jsonpath='{.spec.syncPolicy.automated.prune}' 2>/dev/null)"
  printf 'repoURL=%s|targetRevision=%s|path=%s|helmGitRevision=%s|destNamespace=%s|automated=selfHeal:%s,prune:%s' \
    "$live_repo" "$live_rev" "$live_path" "$live_helm_rev" "$live_dest_ns" "$live_selfheal" "$live_prune"
}

gitops_root_app_exists() {
  pkubectl -n "$ARGOCD_NAMESPACE" get application "$GITOPS_ROOT_APP_NAME" >/dev/null 2>&1
}

gitops_appset_exists() {
  pkubectl -n "$ARGOCD_NAMESPACE" get applicationset "$GITOPS_APPSET_NAME" >/dev/null 2>&1
}

gitops_appproject_exists() {
  pkubectl -n "$ARGOCD_NAMESPACE" get appproject "$GITOPS_PROJECT_NAME" >/dev/null 2>&1
}

gitops_generated_app_exists() {
  pkubectl -n "$ARGOCD_NAMESPACE" get application "$1" >/dev/null 2>&1
}

gitops_app_sync_health() {
  app="$1"
  sync="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null)"
  health="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null)"
  printf '%s %s' "${sync:-Unknown}" "${health:-Unknown}"
}

gitops_wait_for_synced_healthy() {
  app="$1"; timeout="${2:-120}"
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    read -r sync health <<EOF
$(gitops_app_sync_health "$app")
EOF
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      echo "OK: Application/$app is Synced/Healthy"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "FAIL: Application/$app did not reach Synced/Healthy within ${timeout}s (last: sync=$sync health=$health)" >&2
  return 1
}
