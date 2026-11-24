#!/bin/sh
# Phase 6.4a: offline matrix for scripts/terraform/aws-session.sh, the one
# script allowed to run terraform plan/apply/destroy against real AWS.
# Fake `aws` and `terraform` binaries (passed as AWS_BIN/TERRAFORM_BIN)
# play the account and the state; nothing reaches AWS or the network.
# Account IDs are generated with printf, never committed. Each guard has
# at least one case that fails if the guard is removed. Backs
# `make eks-session-regression`.
set -eu

[ -f scripts/terraform/aws-session.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0
GOOD="$(printf '%012d' 4242)"
OTHER="$(printf '%012d' 777)"

mkdir -p "$root/bin"
# Fake aws: answers from files in $FAKE; logs every call and the env it saw.
# The script runs aws/terraform under env -i, so the fakes find their
# fixture through $root/fakedir instead of the environment.
cat > "$root/bin/aws" <<'EOF'
#!/bin/sh
FAKE="$(cat "$(dirname "$0")/../fakedir")"
echo "aws $*" >> "$FAKE/calls"
env > "$FAKE/aws-env"
args="$*"
case "$args" in
  *"sts get-caller-identity"*) cat "$FAKE/account" ;;
  *"ec2 describe-instances"*"karpenter.sh/nodepool"*) cat "$FAKE/karpenter" 2>/dev/null || echo 0 ;;
  *"ec2 describe-nat-gateways"*) cat "$FAKE/nat" 2>/dev/null || true ;;
  *"resourcegroupstaggingapi get-resources"*) cat "$FAKE/tagged" 2>/dev/null || true ;;
  *"kms describe-key"*) echo PendingDeletion ;;
  *"secretsmanager describe-secret"*) echo 2026-12-01T00:00:00 ;;
  *) : ;;
esac
EOF
# Fake terraform: -chdir=DIR, then the command. plan writes the -out file,
# apply writes a state with one managed resource, destroy removes it.
cat > "$root/bin/terraform" <<'EOF'
#!/bin/sh
FAKE="$(cat "$(dirname "$0")/../fakedir")"
echo "terraform $*" >> "$FAKE/calls"
dir="."; case "$1" in -chdir=*) dir="${1#-chdir=}"; shift ;; esac
case "$1" in
  init) : ;;
  plan) for a in "$@"; do case "$a" in -out=*) echo plan > "${a#-out=}" ;; esac; done ;;
  show) echo '{"resource_changes":[{"change":{"actions":["create"]}}]}' ;;
  apply) printf '{"resources":[{"mode":"managed","instances":[{}]}],"outputs":{"vpc_id":{"value":"vpc-x"},"private_subnet_ids":{"value":["s-1","s-2"]},"nat_public_ips":{"value":["198.51.100.7"]}}}' > "$dir/terraform.tfstate" ;;
  destroy) printf '{"resources":[]}' > "$dir/terraform.tfstate" ;;
esac
EOF
chmod +x "$root/bin/aws" "$root/bin/terraform"

# A fresh session directory with a valid config and allowlist.
new_fixture() {
  fx="$root/case$((pass + fail + 1))"; mkdir -p "$fx/session" "$fx/fake"
  cat > "$fx/session/session.env" <<CFG
SESSION_ID=test-session
SESSION_REGION=us-east-1
SESSION_OWNER=not-a-real-owner
SESSION_OPERATOR_CIDR=203.0.113.9/32
SESSION_ADMIN_PRINCIPAL_ARN=arn:aws:iam::aws:role/not-a-real-admin
SESSION_BREAKGLASS_PRINCIPAL_ARN=arn:aws:iam::aws:role/not-a-real-breakglass
SESSION_BUDGET_USD=20
SESSION_BUDGET_EMAIL=operator@example.invalid
SESSION_ADDON_POD_IDENTITY=v1.3.4-eksbuild.1
SESSION_ADDON_VPC_CNI=v1.19.2-eksbuild.1
SESSION_ADDON_COREDNS=v1.11.4-eksbuild.2
SESSION_ADDON_KUBE_PROXY=v1.36.0-eksbuild.1
SESSION_ADDON_METRICS_SERVER=v0.7.2-eksbuild.1
CFG
  echo "$GOOD" > "$fx/session/allowed-accounts"
  echo "$GOOD" > "$fx/fake/account"
  : > "$fx/fake/calls"
}
# Runs the script in the current fixture; extra VAR=value pairs go first.
run() {
  echo "$fx/fake" > "$root/fakedir"
  env -u CI -u GITHUB_ACTIONS AWS_PROFILE=sandbox "$@" \
    SESSION_DIR="$fx/session" FAKE="$fx/fake" \
    AWS_BIN="$root/bin/aws" TERRAFORM_BIN="$root/bin/terraform" \
    bash scripts/terraform/aws-session.sh $ARGS > "$fx/out" 2>&1
}
expect() { # $1=description $2=accept|reject, then the run's VAR=value pairs
  d="$1" want="$2"; shift 2
  if run "$@"; then got=accept; else got=reject; fi
  if [ "$got" = "$want" ]; then echo "OK: $d"; pass=$((pass + 1)); else
    echo "FAIL: $d (expected $want, got $got)" >&2; sed 's/^/    /' "$fx/out" >&2; fail=$((fail + 1)); fi
}
check() { # $1=description, then a test command
  d="$1"; shift
  if "$@"; then echo "OK: $d"; pass=$((pass + 1)); else echo "FAIL: $d" >&2; sed 's/^/    /' "$fx/out" >&2; fail=$((fail + 1)); fi
}
no_tf_mutation() { ! grep -Eq '^terraform .* (apply|destroy)( |$)' "$fx/fake/calls"; }
no_aws_call() { ! grep -q '^aws ' "$fx/fake/calls"; }

# --- layers 1-4: where it may run, and as whom ------------------------------
new_fixture; ARGS="preflight"
expect "preflight on the allowlisted account passes" accept
check "preflight changes nothing" no_tf_mutation

new_fixture; ARGS="preflight"
expect "CI=true is refused" reject CI=true
check "the CI refusal happens before any aws call" no_aws_call

new_fixture; ARGS="preflight"
expect "an empty AWS_PROFILE is refused" reject AWS_PROFILE=
new_fixture; ARGS="preflight"
expect "AWS_PROFILE=default is refused" reject AWS_PROFILE=default
check "the default-profile refusal happens before any aws call" no_aws_call

new_fixture; ARGS="preflight"; echo "$OTHER" > "$fx/fake/account"
expect "an account not on the allowlist is refused" reject
new_fixture; ARGS="preflight"; rm "$fx/session/allowed-accounts"
expect "a missing allowlist is refused" reject

new_fixture; ARGS="preflight"
run AWS_ACCESS_KEY_ID=caller-key AWS_SESSION_TOKEN=caller-token AWS_DEFAULT_PROFILE=default || true
check "caller AWS keys, tokens and profiles never reach aws" sh -c "! grep -Eq '^AWS_(ACCESS_KEY_ID|SESSION_TOKEN|DEFAULT_PROFILE)=' '$fx/fake/aws-env' && grep -qx 'AWS_PROFILE=sandbox' '$fx/fake/aws-env'"

new_fixture; ARGS="preflight"; echo 'SESSION_OWNER=a$(id)' >> "$fx/session/session.env"
expect "a config value with \$ is refused (the file is parsed, never sourced)" reject
new_fixture; ARGS="preflight"; echo 'AWS_PROFILE=default' >> "$fx/session/session.env"
expect "an unknown key in the config is refused" reject

# --- layer 5: the generated provider -----------------------------------------
new_fixture; ARGS="plan budget"
expect "the first stack (budget) plans" accept
prov="$fx/session/work/budget/repo/terraform/envs/sandbox-budget/zz_session_provider.tf"
check "the provider pins allowed_account_ids to the allowlisted account" grep -q "allowed_account_ids = \[\"$GOOD\"\]" "$prov"
check "the provider tags every resource with the project and the session" grep -q 'tags = { Project = "eks-gitops-platform-project", Session = "test-session" }' "$prov"
check "the provider names the profile, never keys" sh -c "grep -q 'profile             = \"sandbox\"' '$prov' && ! grep -Eq 'access_key|secret_key|token' '$prov'"
check "a plan applies nothing" no_tf_mutation

# --- layer 6: CONFIRM, order, saved plans ------------------------------------
ARGS="apply budget"
expect "apply without CONFIRM=yes is refused" reject
check "the refused apply never ran terraform apply" no_tf_mutation
expect "apply with CONFIRM=y is refused" reject CONFIRM=y
expect "apply of the saved plan with CONFIRM=yes runs" accept CONFIRM=yes
check "the saved plan was the one applied" grep -Eq '^terraform .*[a]pply -input=false .*/work/budget/plan.out$' "$fx/fake/calls"
expect "a second apply without a new plan is refused" reject CONFIRM=yes

ARGS="plan eks-platform"
expect "a stack whose previous stack is not applied is refused" reject
new_fixture; ARGS="plan network-platform"
expect "the first network cannot be planned before the budget is applied" reject

new_fixture; ARGS="plan budget"; run || true
sed -i.bak 's/^SESSION_BUDGET_USD=20$/SESSION_BUDGET_USD=30/' "$fx/session/session.env"
ARGS="apply budget"
expect "apply after the inputs changed since the plan is refused" reject CONFIRM=yes
check "the stale plan was never applied" no_tf_mutation

# A full apply order, then destroy rules.
new_fixture
for s in budget network-platform eks-platform network-dev eks-dev identity-dev; do
  ARGS="plan $s"; run || { echo "FAIL: setup plan $s" >&2; sed 's/^/    /' "$fx/out" >&2; }
  ARGS="apply $s"; run CONFIRM=yes || { echo "FAIL: setup apply $s" >&2; sed 's/^/    /' "$fx/out" >&2; }
done
tfv="$fx/session/work/eks-dev/session.tfvars.json"
check "the spoke's API endpoint admits the operator and the hub's NAT IP only" \
  python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])); sys.exit(v["eks_public_access_cidrs"] != ["203.0.113.9/32","198.51.100.7/32"])' "$tfv"
check "the sandbox spoke shares its system nodes (no Karpenter controller)" grep -q '"system_nodes_dedicated": false' "$tfv"
check "the spoke trusts the hub in the same account" grep -q "\"hub_account_id\": \"$GOOD\"" "$tfv"
check "the hub may assume only the dev spoke's role" grep -q "\"dev\": \"$GOOD\"" "$fx/session/work/eks-platform/session.tfvars.json"
check "tfvars are private to the operator" sh -c "[ \"\$(stat -c %a '$tfv' 2>/dev/null || stat -f %Lp '$tfv')\" = 600 ]"

ARGS="destroy network-platform"
expect "destroying a stack while a later one has resources is refused" reject CONFIRM=yes
ARGS="destroy identity-dev"
expect "destroy without CONFIRM=yes is refused" reject
ARGS="destroy identity-dev"
expect "destroy of the last stack with CONFIRM=yes runs" accept CONFIRM=yes
echo 2 > "$fx/fake/karpenter"; ARGS="destroy eks-dev"
expect "destroying eks-dev while Karpenter nodes exist is refused" reject CONFIRM=yes
echo 0 > "$fx/fake/karpenter"
expect "destroying eks-dev once Karpenter nodes are gone runs" accept CONFIRM=yes

# --- sweep -------------------------------------------------------------------
new_fixture; ARGS="sweep"
printf 'arn:aws:kms:us-east-1:%s:key/abc123\tarn:aws:secretsmanager:us-east-1:%s:secret:x/dev/backend-AbCd\tarn:aws:budgets::%s:budget/b\n' "$GOOD" "$GOOD" "$GOOD" > "$fx/fake/tagged"
expect "sweep passes with only deletion-window KMS and secrets and the budget" accept
check "sweep never prints a full account ID" sh -c "! grep -q '$GOOD' '$fx/out'"
new_fixture; ARGS="sweep"; echo "nat-0abc" > "$fx/fake/nat"
expect "sweep fails on a leftover NAT gateway" reject
new_fixture; ARGS="sweep"; printf 'arn:aws:ec2:us-east-1:%s:vpc/vpc-1\n' "$GOOD" > "$fx/fake/tagged"
expect "sweep fails on any other tagged resource" reject

# --- the aws-eks root Application renders the hub-and-spoke chart ----------
fx="$root/render"; mkdir -p "$fx"; : > "$fx/out"
HELM="${HELM_BIN:-.tools/bin/helm}"
rootapp=gitops/root-application-aws-eks.yaml
param() { awk -v n="$1" '$0 ~ "- name: " n "$" {getline; sub(/^[[:space:]]*value: /, ""); print; exit}' "$rootapp"; }
check "the aws-eks root sets profile=aws-eks and the public HTTPS URL on both source and chart" sh -c "
  [ '$(param profile)' = aws-eks ] &&
  [ '$(param repoURL)' = https://github.com/IngMatrix-PGB/eks-gitops-platform-project.git ] &&
  grep -q '^    repoURL: $(param repoURL)\$' '$rootapp'"
if "$HELM" template platform-bootstrap gitops/bootstrap --namespace argocd \
    --set gitRevision=main --set profile="$(param profile)" --set repoURL="$(param repoURL)" > "$fx/render.yaml" 2> "$fx/out"; then
  check "the rendered chart reads only the HTTPS URL (no SSH, so no Git credential on AWS)" sh -c "grep -q 'repoURL: https://github.com/IngMatrix-PGB/' '$fx/render.yaml' && ! grep -q 'git@github.com' '$fx/render.yaml'"
  check "the rendered chart selects the EKS spoke Secrets, never in-cluster" sh -c "grep -q 'eks-spoke-registration' '$fx/render.yaml' && ! grep -q 'kubernetes.default.svc' '$fx/render.yaml'"
else
  echo "FAIL: helm template of the aws-eks profile failed" >&2; sed 's/^/    /' "$fx/out" >&2; fail=$((fail + 1))
fi

echo ""
echo "test-aws-session-guards: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-aws-session-guards: FAILED"; exit 1; }
echo "test-aws-session-guards: OK"
