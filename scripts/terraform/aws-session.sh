#!/usr/bin/env bash
# Phase 6.4a (ADR-0024): the one place this repository may run
# `terraform plan`, `terraform apply` and `terraform destroy` against real
# AWS - a sandbox account, in one authorized session (Phase 6.4b). Written
# and tested offline; nothing here has run against AWS yet.
#
#   aws-session.sh preflight          read-only: identity, allowlist, budget,
#                                     leftovers, add-on versions
#   aws-session.sh plan STACK         saved plan for one stack, with counts
#   aws-session.sh apply STACK        applies that saved plan (CONFIRM=yes)
#   aws-session.sh destroy STACK      destroys one stack (CONFIRM=yes)
#   aws-session.sh output STACK NAME  one output of an applied stack
#   aws-session.sh kubeconfig         .local/kubeconfig-eks-hub and -dev
#   aws-session.sh seed-secret        writes the dev secret's synthetic value
#   aws-session.sh sweep              read-only: fails if anything is left
#
# Stacks, in apply order (destroy is the reverse):
#   budget network-platform eks-platform network-dev eks-dev identity-dev
#
# Layers that keep this on the sandbox account (each covered by
# tests/eks/test-aws-session-guards.sh):
#   1. never in CI (CI / GITHUB_ACTIONS set => refuse);
#   2. AWS_PROFILE is required and is never "default" (on the
#      maintainer's machine the default profile is an unrelated account);
#   3. aws and terraform run under `env -i` with only that profile - no
#      AWS_* key, token or region from the caller survives;
#   4. before anything else, STS must report an account listed in
#      .local/eks-sandbox/allowed-accounts;
#   5. the generated provider pins allowed_account_ids to that account
#      and tags every resource with the project and the session;
#   6. apply and destroy need CONFIRM=yes, one stack at a time, in order;
#      apply only takes a saved plan whose inputs have not changed.
# Each root is copied to .local/eks-sandbox/work/<stack>/; the provider
# file, the tfvars and the state live only there (gitignored). Like the
# emulator script, init runs with -backend=false and no backend block
# exists anywhere: the state is Terraform's local default, on the
# operator's machine only.
set -euo pipefail

[ -f scripts/lab/terraform-root-modules.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }

SESSION_DIR="${SESSION_DIR:-$(pwd)/.local/eks-sandbox}"
SESSION_CONFIG="$SESSION_DIR/session.env"
SESSION_ALLOWLIST="$SESSION_DIR/allowed-accounts"
SESSION_PROJECT="eks-gitops-platform-project"
TERRAFORM_BIN="${TERRAFORM_BIN:-$(pwd)/.tools/bin/terraform}"
AWS_BIN="${AWS_BIN:-$(command -v aws || true)}"
SAFE_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
STACKS="budget network-platform eks-platform network-dev eks-dev identity-dev"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- layer 1: never in CI ---------------------------------------------------
check_not_ci() {
  [ -z "${CI:-}${GITHUB_ACTIONS:-}" ] || fail "aws-session.sh never runs in CI - it is an operator tool for one authorized session"
}

# --- layer 2: an explicit, non-default profile -------------------------------
check_profile() {
  [ -n "${AWS_PROFILE:-}" ] || fail "set AWS_PROFILE to the sandbox account's profile - there is no default"
  [ "$AWS_PROFILE" != "default" ] || fail "AWS_PROFILE=default is refused - name the sandbox profile explicitly"
  case "$AWS_PROFILE" in *[!A-Za-z0-9._-]*) fail "AWS_PROFILE has unexpected characters" ;; esac
}

# --- layer 3: a clean environment for every aws/terraform call ---------------
aws_env() {
  env -i \
    PATH="$SAFE_PATH" HOME="$HOME" \
    AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$SESSION_REGION" AWS_PAGER="" \
    TF_IN_AUTOMATION=1 TF_INPUT=0 \
    TF_PLUGIN_CACHE_DIR="$(pwd)/.tools/cache/terraform-plugins" \
    TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=0 \
    "$@"
}
aws_cli() { aws_env "$AWS_BIN" --output json "$@"; }
tf() { aws_env "$TERRAFORM_BIN" "$@"; }

# --- the session's inputs: KEY=VALUE lines, parsed, never sourced ------------
SESSION_KEYS="SESSION_ID SESSION_REGION SESSION_OWNER SESSION_OPERATOR_CIDR SESSION_ADMIN_PRINCIPAL_ARN SESSION_BREAKGLASS_PRINCIPAL_ARN SESSION_BUDGET_USD SESSION_BUDGET_EMAIL SESSION_ADDON_POD_IDENTITY SESSION_ADDON_VPC_CNI SESSION_ADDON_COREDNS SESSION_ADDON_KUBE_PROXY SESSION_ADDON_METRICS_SERVER"
load_config() {
  [ -f "$SESSION_CONFIG" ] || fail "no $SESSION_CONFIG - copy docs/runbooks/eks-sandbox-session.md's template there"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}" value="${line#*=}"
    case " $SESSION_KEYS " in *" $key "*) : ;; *) fail "unknown key '$key' in $SESSION_CONFIG" ;; esac
    case "$value" in *[\`\$\\\"\']*) fail "$key has a quote, backslash or \$ - plain values only" ;; esac
    printf -v "$key" '%s' "$value"
  done < "$SESSION_CONFIG"
  for k in $SESSION_KEYS; do [ -n "${!k:-}" ] || fail "$k is missing from $SESSION_CONFIG"; done
  [[ "$SESSION_ID" =~ ^[a-z0-9-]{1,32}$ ]] || fail "SESSION_ID must be 1-32 of a-z, 0-9, -"
  [[ "$SESSION_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || fail "SESSION_REGION must look like us-east-1"
  [[ "$SESSION_OPERATOR_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/32$ ]] || fail "SESSION_OPERATOR_CIDR must be one IPv4 address as /32"
  [[ "$SESSION_BUDGET_USD" =~ ^[0-9]+$ ]] || fail "SESSION_BUDGET_USD must be a whole number of USD"
}

# --- layer 4: the account is on the allowlist --------------------------------
SESSION_ACCOUNT=""
check_identity() {
  [ -x "$AWS_BIN" ] || fail "the aws CLI is required"
  [ -f "$SESSION_ALLOWLIST" ] || fail "no $SESSION_ALLOWLIST - one 12-digit sandbox account ID per line"
  acct="$(aws_cli sts get-caller-identity --query Account --output text 2>/dev/null)" || fail "STS did not answer for profile '$AWS_PROFILE' - sign in first (aws sso login --profile $AWS_PROFILE)"
  [[ "$acct" =~ ^[0-9]{12}$ ]] || fail "STS returned no account ID"
  grep -qx "$acct" "$SESSION_ALLOWLIST" || fail "account ****${acct: -4} (profile '$AWS_PROFILE') is not in $SESSION_ALLOWLIST - refusing"
  SESSION_ACCOUNT="$acct"
  echo "OK: profile '$AWS_PROFILE' is sandbox account ****${acct: -4} (on the allowlist), region $SESSION_REGION"
}

# --- layer 5: the provider, generated into the working copy only -------------
write_provider() {
  {
    echo '# Generated by scripts/terraform/aws-session.sh in .local/eks-sandbox. Never committed.'
    echo 'provider "aws" {'
    echo "  region              = \"$SESSION_REGION\""
    echo "  profile             = \"$AWS_PROFILE\""
    echo "  allowed_account_ids = [\"$SESSION_ACCOUNT\"]"
    echo '  default_tags {'
    echo "    tags = { Project = \"$SESSION_PROJECT\", Session = \"$SESSION_ID\" }"
    echo '  }'
    echo '}'
  } > "$1/zz_session_provider.tf"
}

# --- stacks ------------------------------------------------------------------
stack_root() {
  case "$1" in
    budget) echo terraform/envs/sandbox-budget ;;
    network-platform|network-dev) echo terraform/envs/network ;;
    eks-platform|eks-dev) echo terraform/envs/eks ;;
    identity-dev) echo terraform/envs/identity ;;
    *) fail "unknown stack '$1' - one of: $STACKS" ;;
  esac
}
stack_index() { i=0; for s in $STACKS; do [ "$s" = "$1" ] && { echo "$i"; return; }; i=$((i + 1)); done; fail "unknown stack '$1'"; }
stack_dir() { echo "$SESSION_DIR/work/$1/repo/$(stack_root "$1")"; }

prepare_stack() {
  stack="$1" root="$(stack_root "$1")"
  dir="$(stack_dir "$stack")"
  mkdir -p "$dir" "$SESSION_DIR/work/$stack/repo/terraform"
  # Refresh the code, never the state (terraform.tfstate stays in $dir).
  rm -f "$dir"/*.tf
  cp "$root"/*.tf "$root"/.terraform.lock.hcl "$dir/"
  rm -rf "$SESSION_DIR/work/$stack/repo/terraform/modules"
  cp -R terraform/modules "$SESSION_DIR/work/$stack/repo/terraform/"
  write_provider "$dir"
  write_tfvars "$stack" "$SESSION_DIR/work/$stack/session.tfvars.json"
  tf -chdir="$dir" init -backend=false -input=false -lockfile=readonly >/dev/null || fail "terraform init failed for $stack"
}

# Number of resources in a stack's state (0 when never applied).
# Read from the local state file itself: no terraform call, no AWS call.
stack_resources() {
  state="$(stack_dir "$1")/terraform.tfstate"
  [ -f "$state" ] || { echo 0; return; }
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(len(r.get("instances",[])) for r in d.get("resources",[]) if r.get("mode")=="managed"))' "$state"
}

# One output of an applied stack, as JSON.
stack_output() {
  state="$(stack_dir "$1")/terraform.tfstate"
  [ "$(stack_resources "$1")" -gt 0 ] || fail "stack '$1' has no resources in state - apply it first"
  python3 -I -c 'import json,sys; o=json.load(open(sys.argv[1])).get("outputs",{}); sys.exit("no output %s" % sys.argv[2]) if sys.argv[2] not in o else print(json.dumps(o[sys.argv[2]]["value"]))' "$state" "$2" \
    || fail "stack '$1' has no output '$2'"
}

write_tfvars() {
  stack="$1" out="$2"
  hub_nat="" vpc="" subnets=""
  case "$stack" in
    eks-platform) vpc="$(stack_output network-platform vpc_id)"; subnets="$(stack_output network-platform private_subnet_ids)" ;;
    eks-dev) vpc="$(stack_output network-dev vpc_id)"; subnets="$(stack_output network-dev private_subnet_ids)"
             hub_nat="$(stack_output network-platform nat_public_ips)" ;;
  esac
  STACK="$stack" VPC="$vpc" SUBNETS="$subnets" HUB_NAT="$hub_nat" ACCOUNT="$SESSION_ACCOUNT" \
  REGION="$SESSION_REGION" OWNER="$SESSION_OWNER" OPERATOR_CIDR="$SESSION_OPERATOR_CIDR" \
  ADMIN="$SESSION_ADMIN_PRINCIPAL_ARN" BREAKGLASS="$SESSION_BREAKGLASS_PRINCIPAL_ARN" \
  BUDGET="$SESSION_BUDGET_USD" EMAIL="$SESSION_BUDGET_EMAIL" \
  A_PI="$SESSION_ADDON_POD_IDENTITY" A_CNI="$SESSION_ADDON_VPC_CNI" A_DNS="$SESSION_ADDON_COREDNS" \
  A_KP="$SESSION_ADDON_KUBE_PROXY" A_MS="$SESSION_ADDON_METRICS_SERVER" \
  python3 -I - "$out" <<'PY'
import json, os, sys
e = os.environ
stack, region = e["STACK"], e["REGION"]
azs = [region + "a", region + "b"]
v = {}
if stack == "budget":
    v = {"aws_region": region, "owner": e["OWNER"], "monthly_budget_usd": int(e["BUDGET"]),
         "budget_notification_emails": [e["EMAIL"]]}
elif stack.startswith("network-"):
    env = stack.split("-", 1)[1]
    v = {"aws_region": region, "owner": e["OWNER"], "environment": env, "availability_zones": azs,
         "vpc_cidr": "10.0.0.0/16" if env == "platform" else "10.1.0.0/16"}
elif stack.startswith("eks-"):
    env = stack.split("-", 1)[1]
    cidrs = [e["OPERATOR_CIDR"]]
    if env != "platform":
        cidrs += [ip + "/32" for ip in json.loads(e["HUB_NAT"])]
    v = {"aws_region": region, "owner": e["OWNER"], "environment": env,
         "vpc_id": json.loads(e["VPC"]), "private_subnet_ids": json.loads(e["SUBNETS"]),
         "eks_public_access_cidrs": cidrs,
         "admin_principal_arn": e["ADMIN"], "breakglass_principal_arn": e["BREAKGLASS"],
         "pod_identity_agent_addon_version": e["A_PI"], "vpc_cni_addon_version": e["A_CNI"],
         "coredns_addon_version": e["A_DNS"], "kube_proxy_addon_version": e["A_KP"],
         "metrics_server_addon_version": e["A_MS"]}
    if env == "platform":
        v["spoke_account_ids"] = {"dev": e["ACCOUNT"]}
    else:
        v["hub_account_id"] = e["ACCOUNT"]
        # No Karpenter controller in a sandbox session (ADR-0024).
        v["system_nodes_dedicated"] = False
elif stack == "identity-dev":
    v = {"aws_region": region, "owner": e["OWNER"], "environment": "dev"}
with open(sys.argv[1], "w") as f:
    json.dump(v, f, indent=2, sort_keys=True)
PY
  chmod 600 "$out"
}

# Fingerprint of everything a saved plan was made from.
inputs_sha() {
  stack="$1" dir="$(stack_dir "$1")"
  cat "$dir"/*.tf "$SESSION_DIR/work/$stack/session.tfvars.json" | shasum -a 256 | awk '{print $1}'
}

plan_counts() {
  tf -chdir="$(stack_dir "$1")" show -json "$2" | python3 -I -c '
import sys, json
d = json.load(sys.stdin); c = {"create": 0, "update": 0, "delete": 0}
for r in d.get("resource_changes", []):
    for a in r["change"]["actions"]:
        if a in c: c[a] += 1
print("create=%(create)d update=%(update)d delete=%(delete)d" % c)'
}

# --- layer 6: one stack at a time, in order, with CONFIRM=yes -----------------
require_confirm() { [ "${CONFIRM:-}" = "yes" ] || fail "$1 needs CONFIRM=yes - nothing was changed"; }

require_previous_applied() {
  idx="$(stack_index "$1")"; i=0
  for s in $STACKS; do
    [ "$i" -ge "$idx" ] && break
    [ "$(stack_resources "$s")" -gt 0 ] || fail "stack '$s' must be applied before '$1'"
    i=$((i + 1))
  done
}

require_later_destroyed() {
  idx="$(stack_index "$1")"; i=0
  for s in $STACKS; do
    if [ "$i" -gt "$idx" ] && [ "$(stack_resources "$s")" -gt 0 ]; then
      fail "stack '$s' still has resources - destroy it before '$1'"
    fi
    i=$((i + 1))
  done
}

# Karpenter's nodes are not in Terraform state: they must be gone (lab/eks/
# session-hub.sh teardown) before eks-dev or its VPC is destroyed.
require_no_karpenter_nodes() {
  n="$(aws_cli ec2 describe-instances \
    --filters "Name=tag-key,Values=karpenter.sh/nodepool" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'length(Reservations[].Instances[])' --output text)"
  [ "$n" = "0" ] || fail "$n Karpenter instance(s) still exist - run 'make eks-session-teardown' first"
}

cmd_plan() {
  stack="$1"
  require_previous_applied "$stack"
  prepare_stack "$stack"
  work="$SESSION_DIR/work/$stack"
  tf -chdir="$(stack_dir "$stack")" plan -input=false -var-file="$work/session.tfvars.json" -out="$work/plan.out" > "$work/plan.log" 2>&1 \
    || { tail -20 "$work/plan.log" >&2; fail "plan failed for $stack - full log: $work/plan.log"; }
  inputs_sha "$stack" > "$work/plan.sha"
  echo "OK: $stack planned ($(plan_counts "$stack" "$work/plan.out")) - review $work/plan.log, then: make eks-session-apply STACK=$stack CONFIRM=yes"
}

cmd_apply() {
  stack="$1"
  require_confirm "apply of $stack"
  require_previous_applied "$stack"
  work="$SESSION_DIR/work/$stack"
  [ -f "$work/plan.out" ] || fail "no saved plan for $stack - run 'make eks-session-plan STACK=$stack' first"
  prepare_stack "$stack"
  [ "$(inputs_sha "$stack")" = "$(cat "$work/plan.sha")" ] || fail "the code or inputs of $stack changed since its plan - plan again"
  tf -chdir="$(stack_dir "$stack")" apply -input=false "$work/plan.out"
  rm -f "$work/plan.out" "$work/plan.sha"
  echo "OK: $stack applied ($(stack_resources "$stack") resources in state)"
}

cmd_destroy() {
  stack="$1"
  require_confirm "destroy of $stack"
  require_later_destroyed "$stack"
  case "$stack" in eks-dev|network-dev) require_no_karpenter_nodes ;; esac
  [ "$(stack_resources "$stack")" -gt 0 ] || { echo "OK: $stack has nothing to destroy"; return; }
  prepare_stack "$stack"
  tf -chdir="$(stack_dir "$stack")" destroy -input=false -auto-approve -var-file="$SESSION_DIR/work/$stack/session.tfvars.json"
  echo "OK: $stack destroyed"
}

cmd_kubeconfig() {
  for pair in hub:eks-gitops-platform dev:eks-gitops-dev; do
    name="${pair%%:*}" cluster="${pair#*:}"
    kc="$(pwd)/.local/kubeconfig-eks-$name"
    aws_cli eks update-kubeconfig --name "$cluster" --region "$SESSION_REGION" \
      --kubeconfig "$kc" --alias "eks-$name" >/dev/null
    chmod 600 "$kc"
    echo "OK: $kc (context eks-$name, cluster $cluster)"
  done
}

cmd_seed_secret() {
  value_file="$SESSION_DIR/dev-backend-value"
  [ -f "$value_file" ] || fail "no $value_file - write a synthetic value there (e.g. openssl rand -hex 16), mode 600"
  [ "$(stat -c '%a' "$value_file" 2>/dev/null || stat -f '%Lp' "$value_file")" = "600" ] || fail "$value_file must be mode 600"
  name="$(stack_output identity-dev secret_name | tr -d '"')"
  aws_cli secretsmanager put-secret-value --secret-id "$name" --secret-string "file://$value_file" >/dev/null
  echo "OK: synthetic value written to $name (the value is never printed)"
}

# Read-only. A dedicated sandbox account should hold nothing billable from
# this project after destroy; KMS keys and secrets may only remain in their
# deletion windows, and the budget may stay (free, and it still alerts on
# the session's trailing costs).
cmd_sweep() {
  left=0
  note() { echo "LEFT: $*"; left=$((left + 1)); }
  for c in $(aws_cli eks list-clusters --query 'clusters[]' --output text); do note "EKS cluster $c"; done
  for n in $(aws_cli ec2 describe-nat-gateways --filter "Name=state,Values=pending,available,deleting" --query 'NatGateways[].NatGatewayId' --output text); do note "NAT gateway $n"; done
  for a in $(aws_cli ec2 describe-addresses --query 'Addresses[].AllocationId' --output text); do note "Elastic IP $a"; done
  for i in $(aws_cli ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text); do note "EC2 instance $i"; done
  for l in $(aws_cli elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text); do note "load balancer $l"; done
  for l in $(aws_cli elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text); do note "classic load balancer $l"; done
  for v in $(aws_cli ec2 describe-volumes --filters "Name=status,Values=available,in-use" --query 'Volumes[].VolumeId' --output text); do note "EBS volume $v"; done
  for e in $(aws_cli ec2 describe-network-interfaces --filters "Name=status,Values=available" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do note "unattached ENI $e"; done
  for v in $(aws_cli ec2 describe-vpcs --filters "Name=tag:Project,Values=$SESSION_PROJECT" --query 'Vpcs[].VpcId' --output text); do note "VPC $v"; done
  for g in $(aws_cli logs describe-log-groups --log-group-name-prefix /aws/eks/eks-gitops- --query 'logGroups[].logGroupName' --output text); do note "log group $g"; done
  for arn in $(aws_cli resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$SESSION_PROJECT" --query 'ResourceTagMappingList[].ResourceARN' --output text); do
    case "$arn" in
      arn:aws:kms:*:key/*)
        st="$(aws_cli kms describe-key --key-id "$arn" --query 'KeyMetadata.KeyState' --output text)"
        [ "$st" = "PendingDeletion" ] && echo "OK: KMS key ****${arn: -6} pending deletion" || note "KMS key ****${arn: -6} ($st)" ;;
      arn:aws:secretsmanager:*)
        d="$(aws_cli secretsmanager describe-secret --secret-id "$arn" --query 'DeletedDate' --output text)"
        [ "$d" != "None" ] && echo "OK: secret ${arn##*:secret:} scheduled for deletion" || note "secret ${arn##*:secret:}" ;;
      arn:aws:budgets::*) echo "OK: budget kept (free; alerts on trailing costs)" ;;
      *) note "tagged resource ${arn#arn:aws:}" ;;
    esac
  done
  if [ "$left" -gt 0 ]; then fail "sweep found $left leftover(s) - the session is not over"; fi
  echo "OK: sweep found nothing left in $SESSION_REGION (only resources in their deletion windows, and the budget)"
}

cmd_preflight() {
  [ -x "$TERRAFORM_BIN" ] || fail "$TERRAFORM_BIN missing - run 'make tools-install'"
  if [ "$(stack_resources budget)" -gt 0 ]; then echo "OK: budget stack applied"; else echo "NOTE: budget stack not applied yet - it is the first stack"; fi
  existing="$(aws_cli eks list-clusters --query 'length(clusters)' --output text)"
  [ "$existing" = "0" ] || echo "NOTE: $existing EKS cluster(s) already exist in $SESSION_REGION - check the sweep before applying"
  echo "Current EKS add-on versions for Kubernetes 1.36 (put the ones you choose in $SESSION_CONFIG):"
  for a in eks-pod-identity-agent vpc-cni coredns kube-proxy metrics-server; do
    v="$(aws_cli eks describe-addon-versions --addon-name "$a" --kubernetes-version 1.36 \
      --query 'addons[0].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0]' --output text 2>/dev/null || echo "?")"
    echo "  $a: $v"
  done
  echo "OK: preflight done - nothing was changed"
}

cmd="${1:-}"; shift || true
check_not_ci
check_profile
load_config
check_identity
mkdir -p "$SESSION_DIR/work" .tools/cache/terraform-plugins
case "$cmd" in
  preflight) cmd_preflight ;;
  plan) [ $# -eq 1 ] || fail "usage: aws-session.sh plan STACK"; cmd_plan "$1" ;;
  apply) [ $# -eq 1 ] || fail "usage: aws-session.sh apply STACK"; cmd_apply "$1" ;;
  destroy) [ $# -eq 1 ] || fail "usage: aws-session.sh destroy STACK"; cmd_destroy "$1" ;;
  output) [ $# -eq 2 ] || fail "usage: aws-session.sh output STACK NAME"; stack_output "$1" "$2" ;;
  kubeconfig) cmd_kubeconfig ;;
  seed-secret) cmd_seed_secret ;;
  sweep) cmd_sweep ;;
  *) fail "usage: aws-session.sh preflight|plan STACK|apply STACK|destroy STACK|output STACK NAME|kubeconfig|seed-secret|sweep" ;;
esac
