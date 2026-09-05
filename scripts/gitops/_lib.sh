#!/bin/sh
# Shared constants and helpers for lab/gitops/*.sh and tests/gitops/*.sh.
# POSIX-compatible shell only. Sourced, never executed directly. Assumes
# the caller's working directory is the repository root, and that
# scripts/lab/_lib.sh (project cluster/kubeconfig constants, pkubectl)
# and scripts/argocd/_lib.sh (phelm, ARGOCD_NAMESPACE,
# list_namespace_resource_names) have already been sourced first. The
# classifier functions below (Phase 2.6.3a) also call into
# scripts/eso/_lib.sh (eso_release_owns_object) - callers that use them
# must source that file too.

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

gitops_app_uid() {
  pkubectl -n "$ARGOCD_NAMESPACE" get application "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null
}

gitops_app_finalizers() {
  pkubectl -n "$ARGOCD_NAMESPACE" get application "$1" -o jsonpath='{.metadata.finalizers}' 2>/dev/null
}

gitops_app_generation() {
  pkubectl -n "$ARGOCD_NAMESPACE" get application "$1" -o jsonpath='{.metadata.generation}' 2>/dev/null
}

# Generic "N consecutive stable reads" loop (Phase 2.6.3a): $1 is the
# NAME of a predicate function (called with no arguments - POSIX sh has
# no closures, so predicates read module-global variables the caller
# sets beforehand) that must return 0 for "condition currently true".
# $2=required consecutive successes (default 3) $3=poll interval
# seconds (default 15) $4=overall timeout seconds (default 420 - the
# empirically-observed worst case for a stale self-heal retry storm to
# exhaust its own retry budget, per .local/evidence/phase-2.6.3-*). A
# single true read is never sufficient evidence on its own - this is
# the direct fix for the false-positive this project hit twice during
# Phase 2.6.2 testing.
gitops_wait_stable() {
  predicate="$1"; required="${2:-3}"; interval="${3:-15}"; timeout="${4:-420}"
  stable=0
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ] && [ "$stable" -lt "$required" ]; do
    if "$predicate"; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    [ "$stable" -ge "$required" ] && break
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  [ "$stable" -ge "$required" ]
}

# Detects a stuck/stale queued operation on Application $1: its
# embedded source revision (.operation.sync.source.targetRevision)
# differs from the Application's OWN current spec revision
# (.spec.source.targetRevision). Confirmed live during Phase 2.6.2
# testing: self-heal can retry an operation computed against an old
# revision even after spec.source.targetRevision has already moved on,
# because the operation's own manifest snapshot was taken at queue
# time and is never re-evaluated on retry.
gitops_detect_stale_operation() {
  app="$1"
  op_src_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.operation.sync.source.targetRevision}' 2>/dev/null)"
  [ -n "$op_src_rev" ] || return 1
  spec_rev="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null)"
  [ "$op_src_rev" != "$spec_rev" ]
}

# Clears a stuck/queued operation via a merge PATCH only - never a
# delete of the Application. If automated sync is still enabled,
# self-heal re-queues a fresh, correctly-computed operation on its own
# immediately afterward.
gitops_clear_stale_operation() {
  pkubectl patch application "$1" -n "$ARGOCD_NAMESPACE" --type=merge -p '{"operation":null}' >/dev/null 2>&1
}

# Pauses automated sync (self-heal+prune) on Application $1 via a merge
# PATCH only - never deletes or recreates the Application. This
# project's Applications are always rendered with
# {selfHeal:true,prune:true} (see gitops_root_app_desired_fingerprint),
# so gitops_resume_automated_sync always restores that literal value
# rather than a captured one - avoiding ever persisting a paused state
# if a capture step had failed.
gitops_pause_automated_sync() {
  pkubectl patch application "$1" -n "$ARGOCD_NAMESPACE" --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
}

gitops_resume_automated_sync() {
  pkubectl patch application "$1" -n "$ARGOCD_NAMESPACE" --type=merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}' >/dev/null
}

gitops_automated_sync_paused() {
  val="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$1" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)"
  [ -z "$val" ]
}

# Classifies one discovered namespaced object (as printed by `kubectl
# get <type> -o name`, e.g. "role.rbac.authorization.k8s.io/x") into
# exactly one of: argocd-tracked | helm-eso-scoped | kubernetes-builtin
# | unknown. $1=object $2=namespace $3=the Argo CD Application name
# expected to track objects in this namespace. Uses only verifiable
# metadata (the object's own argocd.argoproj.io/tracking-id annotation
# value, or scripts/eso/_lib.sh's Helm-ownership check) - never a
# name-prefix guess.
# Returns 0 if the tracking-id annotation VALUE (never the object's own
# name) on $1 (type/name), namespace $2, structurally parses as
# "<app>:<group>/<kind>:<namespace>/<name>" with the app field exactly
# equal to $3 and the namespace field exactly equal to $2. Deliberately
# tolerant of the kind/name portion: verified empirically this project
# hits two cases where Kubernetes/a controller copies an owning
# object's tracking-id annotation verbatim onto a child it creates -
# a Deployment's ReplicaSet carries the *Deployment's* tracking-id
# (kind reads "Deployment", not "ReplicaSet"), and ESO's target Secret
# (creationPolicy: Owner) carries its *owning ExternalSecret's*
# tracking-id (kind reads "ExternalSecret", not "Secret"). Requiring an
# exact kind/name match would misclassify both as foreign objects, so
# the exact, verified fields are the ones that actually distinguish
# "belongs to this Application" from "belongs to something else": the
# Application name and the namespace, parsed as real annotation
# structure - never a raw substring/prefix match on the whole value,
# and never the object's own name.
gitops_tracking_id_matches_app() {
  gtim_obj="$1"; gtim_ns="$2"; gtim_expected_app="$3"
  gtim_tid="$(pkubectl -n "$gtim_ns" get "$gtim_obj" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null)"
  [ -n "$gtim_tid" ] || return 1
  gtim_app="${gtim_tid%%:*}"
  gtim_rest="${gtim_tid#*:}"
  gtim_nsname="${gtim_rest#*:}"
  [ "$gtim_app" = "$gtim_expected_app" ] || return 1
  case "$gtim_nsname" in
    "${gtim_ns}/"*) return 0 ;;
  esac
  return 1
}

gitops_classify_namespaced_object() {
  obj="$1"; ns="$2"; expected_app="$3"

  case "$obj" in
    serviceaccount/default|configmap/kube-root-ca.crt)
      echo "kubernetes-builtin"; return 0 ;;
    event/*|event.events.k8s.io/*)
      echo "kubernetes-builtin"; return 0 ;;
    endpoints/*)
      # Legacy, deprecated (Kubernetes v1.33+) auto-mirror of a
      # Service with no ownerReference of its own to verify against -
      # an expected byproduct of any Service, not a name-prefix guess.
      echo "kubernetes-builtin"; return 0 ;;
  esac

  if gitops_tracking_id_matches_app "$obj" "$ns" "$expected_app"; then
    echo "argocd-tracked"; return 0
  fi

  # Kubernetes-controller-derived objects that carry no tracking-id of
  # their own at all (confirmed empirically: Pod, EndpointSlice) -
  # resolve exactly one hop via their REAL ownerReference (never a name
  # guess) to a known parent kind this project's workloads always
  # produce, and inherit that parent's classification.
  case "$obj" in
    pod/*)
      owner_kind="$(pkubectl -n "$ns" get "$obj" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)"
      owner_name="$(pkubectl -n "$ns" get "$obj" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)"
      if [ "$owner_kind" = "ReplicaSet" ] && [ -n "$owner_name" ] \
        && gitops_tracking_id_matches_app "replicaset.apps/${owner_name}" "$ns" "$expected_app"; then
        echo "argocd-tracked"; return 0
      fi
      ;;
    endpointslice.discovery.k8s.io/*)
      owner_kind="$(pkubectl -n "$ns" get "$obj" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)"
      owner_name="$(pkubectl -n "$ns" get "$obj" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)"
      if [ "$owner_kind" = "Service" ] && [ -n "$owner_name" ] \
        && gitops_tracking_id_matches_app "service/${owner_name}" "$ns" "$expected_app"; then
        echo "argocd-tracked"; return 0
      fi
      ;;
  esac

  if eso_release_owns_object "$obj" "$ns"; then
    echo "helm-eso-scoped"; return 0
  fi

  echo "unknown"
  return 0
}

# Discovers and classifies every namespaced object in $1, paired with
# $2 (the expected tracking Application name for that namespace).
# Writes one "<class> <object>" line per object to $3. Returns 0 on
# successful discovery+classification (regardless of what was found -
# the caller inspects $3 for any "unknown " line to decide whether to
# abort), 2 on a discovery error (fail closed).
gitops_classify_namespace() {
  # Distinctly-prefixed local variable names throughout: POSIX sh has
  # no real function-local scope, and list_namespace_resource_names()/
  # gitops_classify_namespaced_object() below reassign their own
  # same-named globals (ns, out_file, obj, ...) as a side effect of
  # being called - a same-named variable here would silently be
  # clobbered by the callee. Verified empirically: an earlier version
  # of this function using "ns"/"out_file" directly lost its own
  # output file path this way.
  gcn_ns="$1"; gcn_expected_app="$2"; gcn_out_file="$3"
  gcn_nsinv_tmp="$(mktemp)" || return 2
  if ! list_namespace_resource_names "$gcn_ns" "$gcn_nsinv_tmp"; then
    rm -f "$gcn_nsinv_tmp"
    return 2
  fi

  : > "$gcn_out_file"
  while IFS= read -r gcn_obj; do
    [ -z "$gcn_obj" ] && continue
    gcn_class="$(gitops_classify_namespaced_object "$gcn_obj" "$gcn_ns" "$gcn_expected_app")"
    printf '%s %s\n' "$gcn_class" "$gcn_obj" >> "$gcn_out_file"
  done < "$gcn_nsinv_tmp"
  rm -f "$gcn_nsinv_tmp"
  return 0
}
