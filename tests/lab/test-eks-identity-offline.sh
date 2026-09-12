#!/bin/sh
# Phase 3.3.4b: fully offline positive/negative matrix for
# check_eks_cluster_identity() (scripts/lab/_lib.sh). DESIGNED /
# STATICALLY VALIDATED / NOT DEPLOYED / NOT VALIDATED AGAINST AWS -
# ACTUAL COST: USD 0. Never touches the project's real kind cluster,
# never touches AWS, never touches the network. Every "kubectl" call
# the function under test makes is answered by a fake script this
# file writes under mktemp -d; every "aws" invocation is answered by a
# second fake script that logs the attempt and fails immediately -
# proving the function never shells out to the real AWS CLI. No
# kubeconfig fixture here contains a certificate, token, or exec-
# credential block - just plain strings the fake kubectl echoes back.
# Backs `make lab-test-eks-identity-offline`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
fail=0

# --- fake kubectl: fully controlled by env vars the test sets before
# each call, never reads the kubeconfig file's actual content, never
# touches a network. Logs every invocation (argv only, never any
# credential) to $FAKE_KUBECTL_LOG for the "always passes --kubeconfig
# explicitly, never a bare/ambient call" structural check below. ---
fake_kubectl="$root/kubectl"
cat > "$fake_kubectl" <<'FAKEKUBECTLEOF'
#!/bin/sh
[ -n "${FAKE_KUBECTL_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_KUBECTL_LOG"
case "$*" in
  *"config current-context"*)
    [ -n "${FAKE_KUBECTL_CONTEXT:-}" ] || exit 1
    printf '%s\n' "$FAKE_KUBECTL_CONTEXT"
    exit 0
    ;;
  *"context.cluster"*)
    printf '%s\n' "${FAKE_KUBECTL_CLUSTER_ENTRY:-}"
    exit 0
    ;;
  *"cluster.server"*)
    printf '%s\n' "${FAKE_KUBECTL_SERVER:-}"
    exit 0
    ;;
  *"get --raw /healthz"*)
    [ "${FAKE_KUBECTL_HEALTHZ_OK:-0}" = "1" ] && exit 0 || exit 1
    ;;
  *)
    echo "fake kubectl: unexpected invocation: $*" >&2
    exit 99
    ;;
esac
FAKEKUBECTLEOF
chmod +x "$fake_kubectl"

# --- fake aws: must NEVER be invoked by check_eks_cluster_identity.
# Logs any attempt and fails loudly and immediately - this is the
# "intento de ejecutar AWS CLI" guard. ---
fake_aws_log="$root/aws-invoked.log"
fake_aws="$root/aws"
cat > "$fake_aws" <<FAKEAWSEOF
#!/bin/sh
printf '%s\n' "\$*" >> "$fake_aws_log"
echo "FAKE AWS CLI INVOKED - THIS MUST NEVER HAPPEN: \$*" >&2
exit 1
FAKEAWSEOF
chmod +x "$fake_aws"

# --- baseline "good" fixture: a fully coherent synthetic aws-eks
# identity, all public/synthetic values, never a real account/ARN. ---
good_kubeconfig="$root/eks-kubeconfig.fake"
echo "# fake kubeconfig fixture - no certs, tokens, or exec-credential blocks" > "$good_kubeconfig"
GOOD_PROFILE="aws-eks"
GOOD_CONTEXT="arn:aws:eks:us-east-1:aws:cluster/eks-gitops-platform"
GOOD_CLUSTER="eks-gitops-platform"
GOOD_REGION="us-east-1"
GOOD_ENDPOINT="https://A95FBC180B680B58A6468EF360D16E96.yl4.us-east-1.eks.amazonaws.com"
GOOD_REVISION="main"
GOOD_REPO_URL="git@github.com:IngMatrix-PGB/eks-gitops-platform-project.git"

run_case() {
  desc="$1"; expected_case="$2"
  shift 2
  invocation_log="$root/invocations.log"
  : > "$invocation_log"
  FAKE_KUBECTL_LOG="$invocation_log" KUBECTL_BIN="$fake_kubectl" \
    check_eks_cluster_identity "$@" || true
  if [ "$EKS_IDENTITY_CASE" = "$expected_case" ]; then
    echo "OK: $desc -> EKS_IDENTITY_CASE=$expected_case ($EKS_IDENTITY_DETAIL)"
  else
    echo "FAIL: $desc -> expected EKS_IDENTITY_CASE=$expected_case, got '$EKS_IDENTITY_CASE' ($EKS_IDENTITY_DETAIL)" >&2
    fail=1
  fi
  if [ -s "$fake_aws_log" ]; then
    echo "FAIL: $desc -> the fake aws CLI was invoked: $(cat "$fake_aws_log")" >&2
    fail=1
    : > "$fake_aws_log"
  fi
}

# =============================================================================
# Positive: a fully coherent synthetic identity
# =============================================================================
PATH="$root:$PATH" \
FAKE_KUBECTL_CONTEXT="$GOOD_CONTEXT" \
FAKE_KUBECTL_CLUSTER_ENTRY="$GOOD_CONTEXT" \
FAKE_KUBECTL_SERVER="$GOOD_ENDPOINT" \
FAKE_KUBECTL_HEALTHZ_OK=1 \
  run_case "synthetic identity fully coherent (cluster/region/endpoint/context)" "match" \
    "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

if [ "$fail" -eq 0 ]; then
  echo "OK: the fake AWS CLI was never invoked during the positive case"
fi

# --- structural: every kubectl invocation in the positive case above
# explicitly passed --kubeconfig <the given path> - never a bare/
# ambient call that could silently fall back to a global context ---
if [ -s "$root/invocations.log" ] && ! grep -qv -- "--kubeconfig $good_kubeconfig" "$root/invocations.log"; then
  echo "OK: every kubectl invocation explicitly used --kubeconfig $good_kubeconfig - no implicit fallback to any ambient/global context is possible"
else
  echo "FAIL: at least one kubectl invocation did not explicitly pass --kubeconfig $good_kubeconfig" >&2
  cat "$root/invocations.log" >&2
  fail=1
fi

# =============================================================================
# Negative cases - each demonstrates its exact expected EKS_IDENTITY_CASE
# =============================================================================

run_case "unknown profile" "wrong_profile" \
  "azure" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "aws-eks with no kubeconfig argument" "missing_parameter" \
  "$GOOD_PROFILE" "" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

# kubeconfig equal to the global one - simulate by pointing HOME at a
# throwaway dir whose .kube/config IS the exact path under test.
global_home="$root/fake-home"
mkdir -p "$global_home/.kube"
cp "$good_kubeconfig" "$global_home/.kube/config"
HOME="$global_home" \
  run_case "kubeconfig identical to the global kubeconfig" "kubeconfig_is_global" \
    "$GOOD_PROFILE" "$global_home/.kube/config" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

# kubeconfig identical to the project's own kind kubeconfig - the
# file-existence check inside check_eks_cluster_identity() runs before
# the same-path comparison this case actually exercises, so
# $PROJECT_KUBECONFIG must exist as a plain file here. A clean checkout
# (CI, or any machine that never ran `make lab-create`) has no such
# file yet - create a placeholder only if missing, and remove it again
# immediately after, never touching (or leaving behind) a real kind
# kubeconfig a developer might already have.
kind_kubeconfig_created=0
if [ ! -f "$PROJECT_KUBECONFIG" ]; then
  mkdir -p "$(dirname "$PROJECT_KUBECONFIG")"
  echo "# fake kubeconfig fixture placeholder for offline test - no certs/tokens/keys" > "$PROJECT_KUBECONFIG"
  kind_kubeconfig_created=1
fi
run_case "kubeconfig identical to the project's kind kubeconfig" "kubeconfig_is_kind" \
  "$GOOD_PROFILE" "$PROJECT_KUBECONFIG" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"
if [ "$kind_kubeconfig_created" -eq 1 ]; then
  rm -f "$PROJECT_KUBECONFIG"
fi

run_case "missing expected context" "missing_parameter" \
  "$GOOD_PROFILE" "$good_kubeconfig" "" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

FAKE_KUBECTL_CONTEXT="arn:aws:eks:us-east-1:aws:cluster/some-other-cluster" \
  run_case "kubectl reports a different context than expected" "context_mismatch" \
    "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "missing expected cluster name" "missing_parameter" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

FAKE_KUBECTL_CONTEXT="$GOOD_CONTEXT" FAKE_KUBECTL_CLUSTER_ENTRY="arn:aws:eks:us-east-1:aws:cluster/wrong-cluster" \
  run_case "kubeconfig's cluster entry does not contain the expected cluster name" "cluster_name_mismatch" \
    "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "missing region" "missing_parameter" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "invalid region shape" "invalid_region" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "not-a-region" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "region differs from the one embedded in the endpoint" "invalid_endpoint" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "us-west-2" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "endpoint is not EKS-shaped" "invalid_endpoint" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "https://example.com" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "endpoint embeds a different (but validly-shaped) region" "invalid_endpoint" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "https://A95FBC180B680B58A6468EF360D16E96.yl4.us-west-2.eks.amazonaws.com" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "endpoint is plain HTTP, not HTTPS" "invalid_endpoint" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "http://A95FBC180B680B58A6468EF360D16E96.yl4.us-east-1.eks.amazonaws.com" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "empty endpoint" "missing_parameter" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "" "$GOOD_REVISION" "$GOOD_REPO_URL"

run_case "missing repo URL" "missing_parameter" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" ""

run_case "missing git revision" "missing_parameter" \
  "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "" "$GOOD_REPO_URL"

FAKE_KUBECTL_CONTEXT="$GOOD_CONTEXT" FAKE_KUBECTL_CLUSTER_ENTRY="$GOOD_CONTEXT" FAKE_KUBECTL_SERVER="$GOOD_ENDPOINT" FAKE_KUBECTL_HEALTHZ_OK=0 \
  run_case "API server unreachable" "api_unreachable" \
    "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

# malformed kubectl output: garbage instead of the real cluster entry
FAKE_KUBECTL_CONTEXT="$GOOD_CONTEXT" FAKE_KUBECTL_CLUSTER_ENTRY='{"malformed' \
  run_case "malformed kubectl output (cluster entry)" "cluster_name_mismatch" \
    "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

# attempted AWS CLI invocation: even with PATH pointing at the fake aws
# first, the function must still succeed on a coherent identity AND
# never actually invoke it (proving it doesn't shell out to "aws" at
# all, not merely that a well-behaved test forgot to check)
PATH="$root:$PATH" \
FAKE_KUBECTL_CONTEXT="$GOOD_CONTEXT" FAKE_KUBECTL_CLUSTER_ENTRY="$GOOD_CONTEXT" FAKE_KUBECTL_SERVER="$GOOD_ENDPOINT" FAKE_KUBECTL_HEALTHZ_OK=1 \
  run_case "aws CLI present on PATH but never invoked" "match" \
    "$GOOD_PROFILE" "$good_kubeconfig" "$GOOD_CONTEXT" "$GOOD_CLUSTER" "$GOOD_REGION" "$GOOD_ENDPOINT" "$GOOD_REVISION" "$GOOD_REPO_URL"

# =============================================================================
# Structural: the function itself never mutates anything ("intento de
# mutar antes de completar preflight" - checked by source inspection,
# not by execution, since the function contains no mutating verb at
# all to begin with)
# =============================================================================
eks_identity_fn_body="$(awk '/^check_eks_cluster_identity\(\) \{/{f=1} f{print} f && /^}$/{exit}' scripts/lab/_lib.sh)"
if printf '%s\n' "$eks_identity_fn_body" | grep -qE '"\$KUBECTL_BIN"[^|&;]*(apply|delete|patch|create)'; then
  echo "FAIL: check_eks_cluster_identity()'s own body contains a mutating kubectl verb - it must be read-only end to end" >&2
  fail=1
else
  echo "OK: check_eks_cluster_identity()'s own body contains zero mutating kubectl verbs (apply/delete/patch/create) - it cannot mutate anything by construction"
fi

# =============================================================================
# Regression: the existing local-kind identity check is untouched
# (structural - the new function is additive, never a replacement)
# =============================================================================
if command -v check_cluster_identity >/dev/null 2>&1 || type check_cluster_identity >/dev/null 2>&1; then
  echo "OK: check_cluster_identity() (local-kind) is still defined and callable - unaffected by this addition"
else
  echo "FAIL: check_cluster_identity() is no longer defined" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-eks-identity-offline: FAILED"
  exit 1
fi
echo "test-eks-identity-offline: OK"
