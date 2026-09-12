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

# wait_until <predicate-fn> <timeout-seconds> <interval-seconds>
# Phase 3.2.1 consolidation: calls the shell function named by
# <predicate-fn> (no arguments) every <interval-seconds> until it
# exits 0 or <timeout-seconds> has elapsed. Returns 0 as soon as the
# predicate succeeds, 1 on timeout. Prints nothing and sets no
# variable itself - the predicate function communicates any result
# (e.g. a captured value for the caller to echo) via its own
# caller-visible variables, exactly as each poll-loop this replaces
# already did before this helper existed. A function name (not an
# eval'd string) is used deliberately, to avoid the quoting hazards of
# building a shell command as text.
wait_until() {
  predicate_fn="$1"; timeout="$2"; interval="$3"
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    "$predicate_fn" && return 0
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

# Phase 3.3.4b: DESIGNED / NOT DEPLOYED / NOT VALIDATED AGAINST AWS.
# Fail-closed identity check for a future "aws-eks" profile - a
# separate branch alongside check_cluster_identity() above, never a
# replacement. check_cluster_identity() reads fixed PROJECT_* globals
# because exactly one kind cluster/kubeconfig exists in this project;
# this function instead takes every fact as an EXPLICIT argument - no
# global constant, no implicit fallback to $HOME/.kube/config or to
# $PROJECT_KUBECONFIG - because a future EKS cluster's identity (which
# cluster, which kubeconfig, which region) is precisely the kind of
# fact this project's own governance requires as an explicit runtime
# parameter, never a default baked into Git (ACTUAL COST: USD 0 - this
# function has never been run against a real EKS cluster; every
# reference to "EKS" below is a structural/offline check only).
#
# Never invokes the aws CLI - every check is either a plain string/
# shape comparison, or a read-only Kubernetes API call
# (`kubectl ... get --raw /healthz`, `kubectl ... config view`) against
# whatever server the given kubeconfig points at. If that kubeconfig's
# own user entry happens to use an AWS exec-credential plugin (e.g.
# `aws eks get-token` or `aws-iam-authenticator`), invoking `kubectl`
# against it WOULD shell out to that plugin to obtain a token - this
# function does not call it directly, but cannot prevent kubectl's own
# exec-credential mechanism from doing so if such a kubeconfig is ever
# passed to it for real. That first real invocation is deliberately
# out of scope here (a future, separately authorized operation, per
# docs/runbooks/eks-bootstrap-order.md) - every test in
# tests/lab/test-eks-identity-offline.sh passes a plain, static
# kubeconfig fixture with no exec-credential block at all, specifically
# so this function's own logic can be proven correct without ever
# triggering that mechanism.
#
# Args (all required, all explicit - a missing/empty one is itself a
# fail-closed rejection, "missing_parameter", never a silent default):
#   $1 profile          - must be exactly "aws-eks"
#   $2 kubeconfig        - path to the project's own EKS kubeconfig,
#                          never the ambient/global one, never
#                          $PROJECT_KUBECONFIG (the kind cluster's own)
#   $3 expected_context  - the kubeconfig context name this profile
#                          must resolve to
#   $4 expected_cluster  - the EKS cluster's own logical name (e.g.
#                          terraform/envs/eks's own cluster_name)
#   $5 expected_region   - AWS region shape only (e.g. us-east-1) -
#                          never checked against a real AWS endpoint
#   $6 expected_endpoint - the full https:// API server URL this
#                          profile expects
#   $7 git_revision      - non-empty, explicit (mirrors
#                          GITOPS_DEFAULT_REVISION's own role for
#                          local-kind, but never assumed for aws-eks)
#   $8 repo_url          - non-empty, explicit
#
# Sets EKS_IDENTITY_CASE/EKS_IDENTITY_DETAIL (mirrors
# IDENTITY_CASE/IDENTITY_DETAIL's own convention from
# check_cluster_identity() above). Returns 0 only when
# EKS_IDENTITY_CASE=match. Never mutates anything.
check_eks_cluster_identity() {
  eks_profile="$1"; eks_kubeconfig="$2"; eks_expected_context="$3"
  eks_expected_cluster="$4"; eks_expected_region="$5"
  eks_expected_endpoint="$6"; eks_git_revision="$7"; eks_repo_url="$8"

  EKS_IDENTITY_CASE=""
  EKS_IDENTITY_DETAIL=""

  if [ "$eks_profile" != "aws-eks" ]; then
    EKS_IDENTITY_CASE="wrong_profile"
    EKS_IDENTITY_DETAIL="expected profile 'aws-eks', got '${eks_profile:-<empty>}'"
    return 1
  fi

  for eks_pname in kubeconfig expected_context expected_cluster expected_region expected_endpoint git_revision repo_url; do
    eval "eks_pval=\$eks_${eks_pname}"
    if [ -z "$eks_pval" ]; then
      EKS_IDENTITY_CASE="missing_parameter"
      EKS_IDENTITY_DETAIL="required parameter '$eks_pname' is empty - no implicit default is permitted for the aws-eks profile"
      return 1
    fi
  done

  if [ ! -f "$eks_kubeconfig" ]; then
    EKS_IDENTITY_CASE="kubeconfig_missing"
    EKS_IDENTITY_DETAIL="$eks_kubeconfig does not exist"
    return 1
  fi

  # Never the same file as the ambient global kubeconfig, and never
  # the project's own kind kubeconfig either - two distinct, explicit
  # identities (kind, aws-eks) must never resolve to the same path.
  eks_global_default="${HOME}/.kube/config"
  eks_abs="$(cd "$(dirname "$eks_kubeconfig")" && pwd)/$(basename "$eks_kubeconfig")"
  if [ -f "$eks_global_default" ]; then
    eks_global_abs="$(cd "$(dirname "$eks_global_default")" && pwd)/$(basename "$eks_global_default")"
    if [ "$eks_abs" = "$eks_global_abs" ]; then
      EKS_IDENTITY_CASE="kubeconfig_is_global"
      EKS_IDENTITY_DETAIL="$eks_kubeconfig resolves to the same path as the global kubeconfig ($eks_global_default) - refusing to treat this as isolated"
      return 1
    fi
  fi
  if [ -f "$PROJECT_KUBECONFIG" ]; then
    eks_kind_abs="$(cd "$(dirname "$PROJECT_KUBECONFIG")" && pwd)/$(basename "$PROJECT_KUBECONFIG")"
    if [ "$eks_abs" = "$eks_kind_abs" ]; then
      EKS_IDENTITY_CASE="kubeconfig_is_kind"
      EKS_IDENTITY_DETAIL="$eks_kubeconfig resolves to the same path as the project's own kind kubeconfig ($PROJECT_KUBECONFIG) - the two profiles must never share a kubeconfig file"
      return 1
    fi
  fi

  # Static region-shape check only (identical criterion to terraform/
  # envs/identity's own aws_region variable validation) - never
  # checked against a real AWS endpoint.
  if ! printf '%s' "$eks_expected_region" | grep -qE '^[a-z]{2}-[a-z]+-[0-9]$'; then
    EKS_IDENTITY_CASE="invalid_region"
    EKS_IDENTITY_DETAIL="'$eks_expected_region' does not match the standard AWS region name shape (e.g. us-east-1) - a static format check only"
    return 1
  fi

  # Endpoint shape: https, and the expected region embedded as its own
  # dot-delimited segment, immediately before an EKS domain suffix.
  # Verified against AWS's own documented endpoint format
  # (docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html,
  # re-verified 2026-09-12): "<id>.<region>.eks.amazonaws.com" for
  # IPv4 clusters (AWS's own example has an extra segment before the
  # region too - "A95FBC....yl4.us-west-2.eks.amazonaws.com" - so the
  # prefix is intentionally unconstrained), "<id>.<region>.api.aws" for
  # IPv6 clusters (EKS clusters created after October 2024). Rejects
  # http://, an empty string, and any endpoint whose region segment
  # does not match $eks_expected_region exactly - this is the "región
  # diferente a la derivada del endpoint" cross-check.
  eks_endpoint_pattern="^https://[A-Za-z0-9.-]+\\.${eks_expected_region}\\.(eks\\.amazonaws\\.com|api\\.aws)\$"
  if ! printf '%s' "$eks_expected_endpoint" | grep -qE "$eks_endpoint_pattern"; then
    EKS_IDENTITY_CASE="invalid_endpoint"
    EKS_IDENTITY_DETAIL="'$eks_expected_endpoint' does not match the expected EKS endpoint shape for region '$eks_expected_region' (<id>.$eks_expected_region.eks.amazonaws.com or .api.aws)"
    return 1
  fi

  # --- from here on, the only network activity is a plain, read-only
  # Kubernetes API call against whatever server $eks_kubeconfig points
  # at (never the aws CLI, never an EKS API call) ---

  eks_actual_context="$("$KUBECTL_BIN" --kubeconfig "$eks_kubeconfig" config current-context 2>/dev/null)" || eks_actual_context=""
  if [ "$eks_actual_context" != "$eks_expected_context" ]; then
    EKS_IDENTITY_CASE="context_mismatch"
    EKS_IDENTITY_DETAIL="kubeconfig current-context is '${eks_actual_context:-<none>}', expected '$eks_expected_context'"
    return 1
  fi

  eks_actual_cluster_entry="$("$KUBECTL_BIN" --kubeconfig "$eks_kubeconfig" config view -o jsonpath="{.contexts[?(@.name==\"${eks_expected_context}\")].context.cluster}" 2>/dev/null)" || eks_actual_cluster_entry=""
  case "$eks_actual_cluster_entry" in
    *"${eks_expected_cluster}"*) : ;;
    *)
      EKS_IDENTITY_CASE="cluster_name_mismatch"
      EKS_IDENTITY_DETAIL="context '$eks_expected_context''s cluster entry is '${eks_actual_cluster_entry:-<none>}', which does not contain the expected cluster name '$eks_expected_cluster'"
      return 1
      ;;
  esac

  eks_actual_endpoint="$("$KUBECTL_BIN" --kubeconfig "$eks_kubeconfig" config view -o jsonpath="{.clusters[?(@.name==\"${eks_actual_cluster_entry}\")].cluster.server}" 2>/dev/null)" || eks_actual_endpoint=""
  if [ "$eks_actual_endpoint" != "$eks_expected_endpoint" ]; then
    EKS_IDENTITY_CASE="endpoint_mismatch"
    EKS_IDENTITY_DETAIL="kubeconfig server endpoint is '${eks_actual_endpoint:-<none>}', expected '$eks_expected_endpoint'"
    return 1
  fi

  # API server reachable - a plain, read-only, unauthenticated-tolerant
  # probe (an EKS API server responds to /healthz, or a 401/403, even
  # without valid credentials - either proves reachability without
  # mutating anything). Never `aws eks describe-cluster`, never any
  # other AWS CLI call - this is the same kind of Kubernetes-level
  # check check_cluster_identity()'s own check_ready_and_version()
  # already does for kind, applied here to a different cluster.
  if ! "$KUBECTL_BIN" --kubeconfig "$eks_kubeconfig" --request-timeout=5s get --raw /healthz >/dev/null 2>&1; then
    EKS_IDENTITY_CASE="api_unreachable"
    EKS_IDENTITY_DETAIL="API server at '$eks_actual_endpoint' did not respond to a read-only health check"
    return 1
  fi

  EKS_IDENTITY_CASE="match"
  EKS_IDENTITY_DETAIL="profile aws-eks: context '$eks_expected_context', cluster '$eks_expected_cluster', region '$eks_expected_region' all verified mutually consistent"
  return 0
}

# Phase 3.3.4b: fingerprint of the aws-eks profile's own identity
# facts - the same "compare only declarative fields, never a full-
# object read" principle gitops_root_app_desired_fingerprint() already
# uses. Every input is non-secret (profile/context/cluster/region/
# revision/repoURL are identifiers, never a credential); deliberately
# never includes a certificate, token, username, exec-credential
# block, or Secret data, and never the kubeconfig's own full content.
eks_identity_fingerprint() {
  printf 'profile=%s|context=%s|cluster=%s|region=%s|endpoint=%s|gitRevision=%s|repoURL=%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
