#!/bin/sh
# Shared constants and helpers for lab/kind/*.sh, scripts/lab/*.sh, and
# tests/lab/*.sh. POSIX-compatible shell only - no bashisms (arrays,
# [[ ]], BASH_SOURCE, herestrings). Sourced, never executed directly.
# Assumes the caller's working directory is the repository root - every
# script in this project sources this file only after confirming that.

PROJECT_CLUSTER_NAME="eks-gitops-lab-lite"
PROJECT_KUBECONFIG=".local/kubeconfig"
PROJECT_KIND_CONTEXT="kind-${PROJECT_CLUSTER_NAME}"
PROJECT_NODE_IMAGE="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
PROJECT_K8S_VERSION="v1.36.4"
KIND_BIN=".tools/bin/kind"
KUBECTL_BIN=".tools/bin/kubectl"

require_repo_root() {
  if [ ! -d ".git" ]; then
    echo "FAIL: must be run from the repository root (no .git directory found here)" >&2
    exit 1
  fi
}

require_tools() {
  if [ ! -x "$KIND_BIN" ]; then
    echo "FAIL: $KIND_BIN not found or not executable - run 'make tools-install' first" >&2
    exit 1
  fi
  if [ ! -x "$KUBECTL_BIN" ]; then
    echo "FAIL: $KUBECTL_BIN not found or not executable - run 'make tools-install' first" >&2
    exit 1
  fi
}

# Explicit kubectl wrapper: always the project-local binary, always the
# project-local kubeconfig, never an ambient/merged KUBECONFIG.
pkubectl() {
  KUBECONFIG="$PROJECT_KUBECONFIG" "$KUBECTL_BIN" --kubeconfig "$PROJECT_KUBECONFIG" "$@"
}

# Phase 2.6.3b (Gap 5): reads the TRUE global kubeconfig state at $1
# (default $HOME/.kube/config), immune to any KUBECONFIG already
# exported in the calling shell - `env -u KUBECONFIG` unsets it for
# exactly this one command, and the explicit --kubeconfig flag (which
# kubectl always prioritizes over the environment variable regardless)
# is passed too, so neither mechanism alone has to be trusted. Uses
# this project's own pinned kubectl binary, never a dependency on an
# ambient system kubectl. Never creates or modifies the file. Never
# prints certificate/token/user/cluster content - only a SHA256 of the
# raw file bytes and the resolved context NAME, or the literal string
# "ABSENT" for either field when the file does not exist (a stable,
# comparable representation - never empty-string, which a caller could
# mistake for "not yet read" rather than "genuinely absent").
# Prints "<sha256-or-ABSENT> <context-or-ABSENT>" on one line.
global_kubeconfig_fingerprint() {
  gkf_path="${1:-$HOME/.kube/config}"
  if [ -f "$gkf_path" ]; then
    gkf_sha="$(shasum -a 256 "$gkf_path" | awk '{print $1}')"
    gkf_ctx="$(env -u KUBECONFIG "$KUBECTL_BIN" --kubeconfig "$gkf_path" config current-context 2>/dev/null || true)"
    [ -z "$gkf_ctx" ] && gkf_ctx="ABSENT"
  else
    gkf_sha="ABSENT"
    gkf_ctx="ABSENT"
  fi
  printf '%s %s\n' "$gkf_sha" "$gkf_ctx"
}

# Phase 2.6.3b (Gap 5): fails if the project's own kubeconfig
# ($PROJECT_KUBECONFIG) resolves to the SAME file as the global
# kubeconfig at $1 (default $HOME/.kube/config) - a defensive guard
# against ever measuring the same file twice under two different names
# and mistaking that for genuine isolation. Compares resolved absolute
# paths only, never file content.
assert_kubeconfig_paths_distinct() {
  akpd_global="${1:-$HOME/.kube/config}"
  if [ -f "$PROJECT_KUBECONFIG" ] && [ -f "$akpd_global" ]; then
    akpd_local_abs="$(cd "$(dirname "$PROJECT_KUBECONFIG")" && pwd)/$(basename "$PROJECT_KUBECONFIG")"
    akpd_global_abs="$(cd "$(dirname "$akpd_global")" && pwd)/$(basename "$akpd_global")"
    if [ "$akpd_local_abs" = "$akpd_global_abs" ]; then
      echo "FAIL: project kubeconfig ($PROJECT_KUBECONFIG) resolves to the same path as the global kubeconfig ($akpd_global) - refusing to treat this as isolated" >&2
      return 1
    fi
  fi
  return 0
}

kind_cluster_exists() {
  "$KIND_BIN" get clusters 2>/dev/null | grep -qxF "$PROJECT_CLUSTER_NAME"
}

kubeconfig_points_to_project_cluster() {
  ctx="$(pkubectl config current-context 2>/dev/null)" || return 1
  [ "$ctx" = "$PROJECT_KIND_CONTEXT" ]
}

node_image_digest_matches() {
  container="${PROJECT_CLUSTER_NAME}-control-plane"
  image_id="$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null)" || return 1
  [ -n "$image_id" ] || return 1
  repo_digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$image_id" 2>/dev/null)" || return 1
  expected_digest="${PROJECT_NODE_IMAGE#*@}"
  case "$repo_digest" in
    *"$expected_digest") return 0 ;;
    *) return 1 ;;
  esac
}

check_ready_and_version() {
  # `kind create cluster` returns before the Node object always reports
  # Ready (kubelet/CNI readiness can lag by a few seconds). Wait, bounded,
  # for that expected propagation instead of failing on a false negative;
  # a genuinely unhealthy node still correctly fails once the timeout
  # elapses.
  pkubectl wait --for=condition=Ready node --all --timeout=90s >/dev/null 2>&1 || true

  line="$(pkubectl get nodes --no-headers 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  status="$(printf '%s' "$line" | awk '{print $2}')"
  version="$(printf '%s' "$line" | awk '{print $5}')"
  [ "$status" = "Ready" ] || return 1
  [ "$version" = "$PROJECT_K8S_VERSION" ] || return 1
}

# Six-point identity check. Sets IDENTITY_CASE and IDENTITY_DETAIL.
# Returns 0 only when IDENTITY_CASE=match. Never mutates anything.
check_cluster_identity() {
  IDENTITY_CASE=""
  IDENTITY_DETAIL=""

  cluster_present=false
  kind_cluster_exists && cluster_present=true

  kubeconfig_present=false
  [ -f "$PROJECT_KUBECONFIG" ] && kubeconfig_present=true

  if [ "$cluster_present" = false ] && [ "$kubeconfig_present" = false ]; then
    IDENTITY_CASE="absent"
    IDENTITY_DETAIL="no cluster named '$PROJECT_CLUSTER_NAME' and no $PROJECT_KUBECONFIG - clean slate"
    return 1
  fi

  if [ "$cluster_present" = false ] && [ "$kubeconfig_present" = true ]; then
    IDENTITY_CASE="kubeconfig_orphaned"
    IDENTITY_DETAIL="$PROJECT_KUBECONFIG exists but no cluster named '$PROJECT_CLUSTER_NAME' was found (stale kubeconfig)"
    return 1
  fi

  if [ "$cluster_present" = true ] && [ "$kubeconfig_present" = false ]; then
    IDENTITY_CASE="kubeconfig_missing"
    IDENTITY_DETAIL="cluster '$PROJECT_CLUSTER_NAME' exists but $PROJECT_KUBECONFIG is missing"
    return 1
  fi

  if ! kubeconfig_points_to_project_cluster; then
    IDENTITY_CASE="kubeconfig_elsewhere"
    IDENTITY_DETAIL="$PROJECT_KUBECONFIG does not identify context '$PROJECT_KIND_CONTEXT'"
    return 1
  fi

  if ! node_image_digest_matches; then
    IDENTITY_CASE="baseline_mismatch"
    IDENTITY_DETAIL="node image digest does not match pinned $PROJECT_NODE_IMAGE"
    return 1
  fi

  if ! check_ready_and_version; then
    IDENTITY_CASE="baseline_mismatch"
    IDENTITY_DETAIL="node is not Ready, or its version is not $PROJECT_K8S_VERSION"
    return 1
  fi

  IDENTITY_CASE="match"
  IDENTITY_DETAIL="cluster '$PROJECT_CLUSTER_NAME' matches the pinned baseline and is healthy"
  return 0
}
