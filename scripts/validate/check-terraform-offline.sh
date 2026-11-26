#!/usr/bin/env bash
# Deterministic, permanent enforcement of the Terraform offline
# contract (originally Phase 2.7.1, extended in Phase 3.1 - see
# docs/adr/0011-terraform-foundation.md and
# docs/adr/0012-network-eks-iac-foundation.md): Terraform/AWS provider
# pinned exactly IN EVERY ROOT MODULE, a real lock file naming the
# expected provider in every root module, no configured (non-empty)
# backend block anywhere, no real infrastructure resource/data source
# outside a narrow documented allowlist, no operative `provider "aws"`
# block, every AWS-referencing Terraform test declares mock_provider
# "aws", no real (shell/Makefile/workflow) `terraform plan`/`terraform
# apply` invocation, no GitHub Actions id-token/aws-actions/AWS-
# credential surface, no real AWS account ID/role ARN, offline targets
# use `terraform init -backend=false`, and no .terraform/ cache, state,
# plan, zip, or binary is tracked in Git.
#
# Root-module discovery (Phase 3.1): the canonical plan
# (.local/evidence/phase-2.7-eks-aws-foundation-plan.md, S5.1) requires
# several independent Terraform root modules, each with its own
# versions.tf/.terraform.lock.hcl/state - terraform/ itself,
# terraform/bootstrap/, and one directory per terraform/envs/<name>/.
# discover_terraform_root_modules() below finds these by DIRECTORY
# STRUCTURE alone, never a manually-maintained list and never by
# checking for the presence of any specific file inside a candidate -
# a root module directory that is missing its own versions.tf is still
# discovered by this rule and then fails checks 1/2 for exactly that
# reason, rather than being silently skipped because the very file
# whose absence is the failure was also the discovery key. Adding a new
# terraform/envs/<anything>/ is enforced automatically, with no
# tooling change and no registration step to forget.
#
# Backend-block semantic exception (Phase 3.1): a `backend "s3" {}`
# (or any backend block whose body contains only blank lines/comments)
# is an intentionally EMPTY/PARTIAL declaration - the real
# bucket/key/region are supplied later via `-backend-config` flags at
# a real, future, separately-authorized `terraform init`, never
# hardcoded now. This is allowed. A backend block carrying ANY real
# attribute (bucket, key, region, dynamodb_table, profile,
# access_key, ...) is a configured, active backend and still fails
# closed - see check 5 and find_configured_backend_blocks() below.
#
# Semantic exception, deliberately NOT flagged as a real terraform
# apply: `command = apply` inside a `.tftest.hcl` run block is HCL
# configuration for Terraform's own built-in test framework, evaluated
# entirely against mock_provider - never a shell invocation of the
# terraform binary. This script only ever scans Makefile/*.sh/.github/
# workflows/*.yml for a literal `terraform ... plan`/`terraform ...
# apply` CLI invocation - it never scans *.tftest.hcl files for that
# pattern at all, so a test file's `command = apply` line can never be
# misclassified as a real apply. See check 9 below.
#
# Backs `make check-terraform-offline` (folded into `make validate`).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$here/_lib.sh"

# Deliberately never forces cd to this script's own on-disk location -
# every path below is relative to the CALLER's working directory
# (exactly like check-forbidden-terms.sh and every other
# scripts/validate/*.sh check), which must be a repository root for
# list_versionable_files()/`git ls-files` to mean anything. This is
# what makes the script equally correct when Make invokes it from the
# real repository root and when tests/terraform/test-offline-contract.sh
# invokes this exact same script against a throwaway fixture repository
# it has cd'd into - never a copy, never a re-implementation.
if [ ! -d ".git" ]; then
  echo "FAIL: must be run from a git repository root (list_versionable_files requires one; no .git found in $(pwd))" >&2
  exit 1
fi

fail=0

ok() { echo "OK: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

# Root-module discovery is NOT re-implemented here - it is sourced,
# purely for its function definition, from
# scripts/lab/terraform-root-modules.sh, the single source of truth
# both this checker and the Makefile's terraform-* targets share. See
# that file's own header comment for the exact discovery rule.
# shellcheck source=../lab/terraform-root-modules.sh
TERRAFORM_ROOT_MODULES_SOURCE_ONLY=1 . "$here/../lab/terraform-root-modules.sh"

root_modules="$(discover_terraform_root_modules)"
root_module_count="$(printf '%s\n' "$root_modules" | grep -c . || true)"
ok "discovered $root_module_count Terraform root module(s): $(printf '%s' "$root_modules" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

# Every check below that scans "all .tf files" does so over exactly
# this list - tracked-or-would-be-tracked .tf files under terraform/ -
# never a raw directory walk. terraform/.terraform/ (the provider
# plugin cache) is gitignored and contains no .tf files today, but this
# is enforced by construction here, not left to depend on that
# incidental fact.
tf_files="$(list_versionable_files | grep -E '^terraform/.*\.tf$' || true)"

# $1=extended-regex pattern. Scans exactly $tf_files (never a raw
# directory walk), printing "file:lineno:content" for every match,
# exactly like `grep -rn` would - but only across files this project
# actually versions.
grep_over_tf_files() {
  pattern="$1"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    grep -Hn -E "$pattern" "$f" 2>/dev/null || true
  done <<EOF_TF
$tf_files
EOF_TF
}

# --- 1/2/3/4, per discovered root module: Terraform CLI and AWS
# provider each pinned EXACTLY (a bare "=" constraint, never ~>, >=, or
# an unconstrained version); a real lock file present and naming the
# expected provider. Runs once per root module discovered above, never
# once total - a root module missing any of this is reported by its
# own path, not conflated with any other root's result. ----------------
while IFS= read -r root; do
  [ -z "$root" ] && continue
  versions_tf="$root/versions.tf"
  lock_file="$root/.terraform.lock.hcl"

  if [ ! -f "$versions_tf" ]; then
    bad "$versions_tf not found"
  else
    if grep -Eq '^[[:space:]]*required_version[[:space:]]*=[[:space:]]*"=[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+"[[:space:]]*"?[[:space:]]*$' "$versions_tf"; then
      ok "Terraform required_version is pinned exactly in $versions_tf"
    else
      bad "$versions_tf does not pin required_version exactly (expected required_version = \"= X.Y.Z\")"
    fi

    if awk '
      /source[[:space:]]*=[[:space:]]*"hashicorp\/aws"/ { found_source=1 }
      found_source && /^[[:space:]]*version[[:space:]]*=[[:space:]]*"=[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+"[[:space:]]*$/ { found_version=1 }
      END { exit !(found_source && found_version) }
    ' "$versions_tf"; then
      ok "AWS provider (hashicorp/aws) is pinned exactly in $versions_tf"
    else
      bad "$versions_tf does not pin the hashicorp/aws provider exactly (expected version = \"= X.Y.Z\" under source = \"hashicorp/aws\")"
    fi
  fi

  if [ ! -f "$lock_file" ]; then
    bad "$lock_file not found"
  else
    ok "$lock_file is present"
    if grep -q 'provider "registry.terraform.io/hashicorp/aws"' "$lock_file"; then
      ok "$lock_file records the expected provider (registry.terraform.io/hashicorp/aws)"
    else
      bad "$lock_file does not record registry.terraform.io/hashicorp/aws"
    fi
  fi
done <<EOF_ROOTS
$root_modules
EOF_ROOTS

# --- 5. No CONFIGURED backend block anywhere in tracked Terraform
# files. An empty/partial backend block ("backend \"s3\" {}", or a
# multi-line block whose body is only blank lines/comments) is
# explicitly allowed (Phase 3.1, header comment) - only a block
# carrying a real attribute (bucket, key, region, dynamodb_table,
# profile, access_key, ...) fails closed. Block-aware, not a per-line
# pattern match, since "configured or not" is a property of the whole
# block body, not any single line. ------------------------------------
find_configured_backend_blocks() {
  file="$1"
  awk '
    BEGIN { in_backend = 0; has_attr = 0; start_line = 0 }
    /^[[:space:]]*backend[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*\{[[:space:]]*\}[[:space:]]*$/ { next }
    /^[[:space:]]*backend[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*\{[[:space:]]*$/ {
      in_backend = 1; has_attr = 0; start_line = NR; next
    }
    in_backend && /^[[:space:]]*\}[[:space:]]*$/ {
      if (has_attr) { printf "%s:%d: configured backend block (real attribute present)\n", FILENAME, start_line }
      in_backend = 0
      next
    }
    in_backend {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "" && substr(line, 1, 1) != "#" && substr(line, 1, 2) != "//") { has_attr = 1 }
    }
  ' "$file"
}

backend_hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  hit="$(find_configured_backend_blocks "$f")"
  [ -n "$hit" ] && backend_hits="$backend_hits
$hit"
done <<EOF_TF
$tf_files
EOF_TF

if [ -n "$backend_hits" ]; then
  bad "a configured (non-empty) backend block was found - only an empty/partial backend declaration (e.g. backend \"s3\" {}) is allowed, never a real bucket/key/region/credential:"
  printf '%s\n' "$backend_hits" >&2
else
  ok "no configured backend block exists in any tracked .tf file (an empty/partial backend declaration, if any, is allowed)"
fi

# --- 6a. Zero resource "aws_*" blocks in the ROOT terraform/ module
# (terraform/*.tf directly - the Phase 2.7.1 toolchain smoke-test
# module, which stays permanently resource-free, no exception). Phase
# 3.1 explicitly authorizes real (never-applied) AWS resource blocks in
# terraform/bootstrap/ and terraform/envs/*/ - that is the entire
# purpose of those modules (e.g. bootstrap/'s aws_s3_bucket state
# bucket) - so this check is scoped to the root module only, never
# repo-wide. Inertness is enforced by the OTHER checks (no configured
# backend, no operative provider "aws" block, no real plan/apply, no
# credentials) - never by pretending no resource can be written. -------
root_tf_files="$(printf '%s\n' "$tf_files" | grep -E '^terraform/[^/]+\.tf$' || true)"
resource_hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  hit="$(grep -Hn -E '^[[:space:]]*resource[[:space:]]*"aws_[A-Za-z0-9_]+"' "$f" 2>/dev/null || true)"
  [ -n "$hit" ] && resource_hits="$resource_hits
$hit"
done <<EOF_ROOT_TF
$root_tf_files
EOF_ROOT_TF
if [ -n "$resource_hits" ]; then
  bad "a real AWS resource block was found in the root terraform/ module (not authorized there - it must stay the permanently resource-free toolchain smoke test; bootstrap/ and envs/*/ are the authorized locations):"
  printf '%s\n' "$resource_hits" >&2
else
  ok "no AWS resource block exists in the root terraform/ module (terraform/*.tf)"
fi

# --- 6b. data "aws_*" blocks are allowed ONLY for a narrow, explicit
# allowlist - fail closed on any other AWS data source type, never a
# blocklist of "known-bad" service names. aws_caller_identity/
# aws_region are the original Phase 2.7.1 toolchain-smoke identity/
# region introspection sources. aws_iam_policy_document is added in
# Phase 3.2 for a different, evidence-based reason: it is the standard,
# AWS-recommended mechanism for authoring IAM policy JSON in Terraform
# (registry.terraform.io/providers/hashicorp/aws/latest/docs/data-
# sources/iam_policy_document, re-verified 2026-09-08) and, critically,
# it never contacts AWS at all, even under a real, unmocked provider -
# its .json output is computed entirely client-side from the given
# statement blocks. This is a DIFFERENT allowance than
# aws_availability_zones (explicitly NOT added, per instruction - that
# data source really would call AWS in a real, future apply); this
# expansion covers only a data source with zero AWS contact in any
# circumstance. ---------------------------------------------------
allowed_aws_data_sources="aws_caller_identity aws_region aws_iam_policy_document"
data_source_lines="$(grep_over_tf_files '^[[:space:]]*data[[:space:]]*"aws_[A-Za-z0-9_]+"')"
data_ok=1
if [ -n "$data_source_lines" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ds_type="$(printf '%s' "$line" | sed -E 's/^[^:]+:[0-9]+:[[:space:]]*data[[:space:]]*"(aws_[A-Za-z0-9_]+)".*$/\1/')"
    match=0
    for allowed in $allowed_aws_data_sources; do
      [ "$ds_type" = "$allowed" ] && match=1
    done
    if [ "$match" -ne 1 ]; then
      bad "AWS data source '$ds_type' is not on the allowlist ($allowed_aws_data_sources): $line"
      data_ok=0
    fi
  done <<EOF_DATA
$data_source_lines
EOF_DATA
fi
if [ "$data_ok" -eq 1 ]; then
  ok "every AWS data source (if any) is on the narrow toolchain-smoke allowlist ($allowed_aws_data_sources)"
fi

# --- 6c. No operative provider "aws" block anywhere outside a test
# file - Phase 2.7.1 never configures a real, runnable AWS provider. ---
provider_block_hits="$(grep_over_tf_files '^[[:space:]]*provider[[:space:]]*"aws"[[:space:]]*\{')"
if [ -n "$provider_block_hits" ]; then
  bad "an operative provider \"aws\" block was found in a real .tf file (not authorized until a real infrastructure phase):"
  printf '%s\n' "$provider_block_hits" >&2
else
  ok "no operative provider \"aws\" block exists in any real (non-test) .tf file"
fi

# --- 7. Every .tftest.hcl file that references an aws_ resource/data
# source must declare mock_provider "aws". -----------------------------
while IFS= read -r -d '' tf; do
  if grep -q 'aws_' "$tf" 2>/dev/null; then
    if grep -q 'mock_provider[[:space:]]*"aws"' "$tf" 2>/dev/null; then
      ok "$tf references aws_* and declares mock_provider \"aws\""
    else
      bad "$tf references aws_* but does not declare mock_provider \"aws\""
    fi
  fi
done < <(find terraform -name '*.tftest.hcl' -print0 2>/dev/null)

# --- 8. id-token: write / aws-actions/* / AWS credential variables or
# secrets never appear in any GitHub Actions workflow. -----------------
# Phase 5.1b: one narrow exception - .github/workflows/image.yml may hold
# id-token: write for Sigstore keyless signing (GitHub OIDC to Fulcio,
# never to AWS). check-supply-chain restricts it further to that file's
# publish job, on push to main only. Every other workflow, and every AWS
# rule below, is unchanged.
workflow_dir=".github/workflows"
if [ -d "$workflow_dir" ]; then
  id_token_hits="$(grep -rEn '^[[:space:]]*id-token[[:space:]]*:[[:space:]]*write' "$workflow_dir" 2>/dev/null | grep -v "^${workflow_dir}/image\.yml:" || true)"
  if [ -n "$id_token_hits" ]; then
    bad "id-token: write found in a workflow other than image.yml (not authorized - no OIDC/AWS auth; Sigstore signing lives only in image.yml):"
    printf '%s\n' "$id_token_hits" >&2
  else
    ok "no id-token: write in any workflow except image.yml (Sigstore signing, Phase 5.1b)"
  fi

  aws_actions_hits="$(grep -rEn 'aws-actions/' "$workflow_dir" 2>/dev/null || true)"
  if [ -n "$aws_actions_hits" ]; then
    bad "an aws-actions/* reference was found (not authorized in Phase 2.7.1):"
    printf '%s\n' "$aws_actions_hits" >&2
  else
    ok "no aws-actions/* reference in any workflow"
  fi

  aws_cred_pattern='AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|secrets\.AWS_|vars\.AWS_|AWS_ROLE_ARN|role-to-assume'
  aws_cred_hits="$(grep -rEn "$aws_cred_pattern" "$workflow_dir" 2>/dev/null || true)"
  if [ -n "$aws_cred_hits" ]; then
    bad "an AWS credential variable/secret reference was found in a workflow:"
    printf '%s\n' "$aws_cred_hits" >&2
  else
    ok "no AWS credential variable/secret reference in any workflow"
  fi
else
  bad "$workflow_dir not found"
fi

# --- 9. No real `terraform ... plan`/`terraform ... apply` CLI
# invocation in Makefile/*.sh/workflows. This deliberately never scans
# *.tftest.hcl (see header comment) - a test file's `command = apply`/
# `command = plan` is HCL test-framework configuration, not a shell
# invocation, and is correctly out of this check's scope by file type
# alone, not by pattern-matching around it. ----------------------------
real_cmd_files=""
while IFS= read -r f; do
  case "$f" in
    Makefile|*.sh|.github/workflows/*.yml|.github/workflows/*.yaml) real_cmd_files="$real_cmd_files
$f" ;;
  esac
done < <(list_versionable_files)

plan_apply_pattern='terraform[^"'"'"'\n]*[[:space:]](plan|apply)([[:space:]]|$)'
# Phase 5.2a (ADR-0018): the one exception. scripts/terraform/emulator.sh
# may run plan/apply/destroy, and only against the local emulator. It is
# skipped here; check 9b below fails the whole check if it loses a guard.
# A call to that script (Makefile, workflow) is not itself a Terraform
# invocation, so its path is removed from a line before matching.
emulator_script="scripts/terraform/emulator.sh"
# Phase 6.4a (ADR-0024): the second exception. scripts/terraform/aws-
# session.sh may run plan/apply/destroy against one allowlisted sandbox
# account, operator-only; check 9f below fails the whole check if it loses
# a guard, and no workflow may call it.
session_script="scripts/terraform/aws-session.sh"
plan_apply_hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  [ "$f" = "$emulator_script" ] && continue
  [ "$f" = "$session_script" ] && continue
  hit="$(sed -e 's#scripts/terraform/emulator\.sh##g' -e 's#scripts/terraform/aws-session\.sh##g' "$f" 2>/dev/null | grep -Ein "$plan_apply_pattern" 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    plan_apply_hits="$plan_apply_hits
$f:
$hit"
  fi
done <<EOF_FILES
$real_cmd_files
EOF_FILES

if [ -n "$plan_apply_hits" ]; then
  bad "a real 'terraform plan'/'terraform apply' CLI invocation was found (Phase 2.7.1 is offline-only):"
  printf '%s\n' "$plan_apply_hits" >&2
else
  ok "no real 'terraform plan'/'terraform apply' CLI invocation in Makefile/*.sh/workflows"
fi

# --- 9b. The emulator exception keeps every guard (ADR-0018). Each
# marker is one layer that keeps plan/apply away from real AWS; losing
# any of them fails closed. Only checked when the script exists. --------
if [ -f "$emulator_script" ]; then
  em_missing=""
  em_need() { grep -Eq -- "$2" "$emulator_script" || em_missing="$em_missing
  - $1"; }
  em_need "emulator image pinned by digest" '^TF_EMULATOR_IMAGE="[^"]+@sha256:[0-9a-f]{64}"$'
  em_need "default endpoint on loopback" '^TF_EMULATOR_ENDPOINT="\$\{TF_EMULATOR_ENDPOINT:-http://(localhost|127\.0\.0\.1):[0-9]+\}"$'
  em_need "loopback-only endpoint check" 'http://127\.0\.0\.1:\[0-9\]\*\|http://localhost:\[0-9\]\*\) : ;;'
  em_need "terraform runs under env -i" '^[[:space:]]*env -i \\$'
  em_need "AWS config file disabled" 'AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null'
  em_need "provider pinned to the emulator account" 'allowed_account_ids[[:space:]]+= \[\\"\$EMULATOR_ACCOUNT\\"\]'
  em_need "every service endpoint sent to the emulator" 'for s in \$EMULATOR_SERVICES; do printf .* "\$TF_EMULATOR_ENDPOINT"; done'
  em_need "ci compares every root with terraform/emulator-coverage.tsv" 'rc=0; compare_coverage \|\| rc=1'
  if grep -Eq 'backend-config|backend "' "$emulator_script"; then em_missing="$em_missing
  - no backend configuration (state stays in the scratch directory)"; fi
  # The identity check must run before any root in the plan/apply branch.
  if ! awk '/^  plan\|apply\|coverage\|ci\)/{b=1} b && /check_identity/{ok=1} b && /run_root/{print (ok ? "ok" : "late"); exit}' "$emulator_script" | grep -qx ok; then
    em_missing="$em_missing
  - emulator identity checked before any plan/apply"
  fi
  # Phase 4d: every AWS service the repository's own Terraform calls must
  # have an emulator endpoint; a missing one would send that service's
  # calls to the real AWS endpoint. Resource and data source types map to
  # endpoint names here; an unknown prefix fails closed until mapped.
  # (The pinned upstream modules' extra services - sqs, events, logs,
  # cloudwatch - are kept in EMULATOR_SERVICES by hand.)
  em_services="$(sed -n 's/^EMULATOR_SERVICES="\([^"]*\)"$/\1/p' "$emulator_script")"
  em_types="$(grep_over_tf_files '^[[:space:]]*(resource|data)[[:space:]]+"aws_[a-z0-9_]+"' | sed -E 's/^[^:]+:[0-9]+:[[:space:]]*(resource|data)[[:space:]]+"(aws_[a-z0-9_]+)".*$/\2/' | sort -u)"
  for t in $em_types; do
    case "$t" in
      aws_iam_policy_document|aws_region) continue ;;  # rendered client-side, no API call
      aws_caller_identity) svc=sts ;;
      aws_accessanalyzer_*) svc=accessanalyzer ;;
      aws_budgets_*) svc=budgets ;;
      aws_cloudtrail*) svc=cloudtrail ;;
      aws_cloudwatch_log_*) svc=logs ;;
      aws_cloudwatch_event_*) svc=events ;;
      aws_cloudwatch_*) svc=cloudwatch ;;
      aws_config_*) svc=configservice ;;
      aws_ebs_*|aws_ec2_*|aws_vpc*|aws_subnet*|aws_security_group*) svc=ec2 ;;
      aws_ecr_*) svc=ecr ;;
      aws_eks_*) svc=eks ;;
      aws_guardduty_*) svc=guardduty ;;
      aws_iam_*) svc=iam ;;
      aws_identitystore_*) svc=identitystore ;;
      aws_kms_*) svc=kms ;;
      aws_organizations_*) svc=organizations ;;
      aws_s3_account_*) svc=s3control ;;
      aws_s3_*) svc=s3 ;;
      aws_secretsmanager_*) svc=secretsmanager ;;
      aws_securityhub_*) svc=securityhub ;;
      aws_sqs_*) svc=sqs ;;
      aws_ssm_*) svc=ssm ;;
      aws_ssoadmin_*) svc=ssoadmin ;;
      *) em_missing="$em_missing
  - $t: no emulator service mapped for it in check-terraform-offline (9b) - map it and add its endpoint to EMULATOR_SERVICES"; continue ;;
    esac
    case " $em_services " in *" $svc "*) : ;; *) em_missing="$em_missing
  - $t calls '$svc', which has no emulator endpoint in EMULATOR_SERVICES (its calls would reach real AWS)" ;; esac
  done
  if [ -n "$em_missing" ]; then
    bad "$emulator_script lost a guard that keeps plan/apply on the local emulator:$em_missing"
  else
    ok "$emulator_script keeps every emulator guard (pinned image, loopback, env -i, no AWS config, allowed_account_ids, all endpoints, an endpoint for every service the code calls, no backend, identity first)"
  fi
fi

# --- 9c. No script, Makefile or workflow other than the emulator script
# writes a provider "aws" block (this checker and its own regression
# test only name it). -----------------------------------------------------
gen_provider_hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  case "$f" in
    "$emulator_script"|"$session_script"|scripts/validate/check-terraform-offline.sh|tests/terraform/test-offline-contract.sh) continue ;;
  esac
  # A heredoc line or an echo/printf that emits the block's opening line.
  hit="$(grep -En '^[[:space:]]*((echo|printf)[^#]*)?provider[[:space:]]+\\?"aws\\?"[[:space:]]*\{' "$f" 2>/dev/null || true)"
  [ -n "$hit" ] && gen_provider_hits="$gen_provider_hits
$f:
$hit"
done <<EOF_FILES
$real_cmd_files
EOF_FILES
if [ -n "$gen_provider_hits" ]; then
  bad "a provider \"aws\" block is written outside $emulator_script and $session_script:"
  printf '%s\n' "$gen_provider_hits" >&2
else
  ok "no script, Makefile or workflow other than $emulator_script and $session_script writes a provider \"aws\" block"
fi

# --- 9f. The sandbox-session exception keeps every guard (Phase 6.4a,
# ADR-0024). Each marker is one layer that keeps plan/apply on one
# allowlisted sandbox account, run by an operator; losing any of them, or
# any workflow calling the script, fails closed. -------------------------
if [ -f "$session_script" ]; then
  ss_missing=""
  ss_need() { grep -Eq -- "$2" "$session_script" || ss_missing="$ss_missing
  - $1"; }
  ss_need "never in CI" '^  \[ -z "\$\{CI:-\}\$\{GITHUB_ACTIONS:-\}" \] \|\| fail'
  ss_need "AWS_PROFILE=default refused" '^  \[ "\$AWS_PROFILE" != "default" \] \|\| fail'
  ss_need "aws and terraform run under env -i" '^  env -i \\$'
  ss_need "account checked against the allowlist" 'grep -qx "\$acct" "\$SESSION_ALLOWLIST" \|\| fail'
  ss_need "provider pinned to the allowlisted account" 'allowed_account_ids = \[\\"\$SESSION_ACCOUNT\\"\]'
  ss_need "apply and destroy need CONFIRM=yes" '\[ "\$\{CONFIRM:-\}" = "yes" \] \|\| fail'
  ss_need "apply takes only an unchanged saved plan" '\[ "\$\(inputs_sha "\$stack"\)" = "\$\(cat "\$work/plan.sha"\)" \] \|\| fail'
  if grep -Eq 'backend-config|backend "' "$session_script"; then ss_missing="$ss_missing
  - no backend configuration (local state under .local/ only)"; fi
  # The guards run, in this order, before the command is dispatched.
  if [ "$(awk '/^check_not_ci$/{a=NR} /^check_profile$/{b=NR} /^check_identity$/{c=NR} /^case "\$cmd" in$/{d=NR} END{print (a && b && c && d && a < b && b < c && c < d) ? "ok" : "bad"}' "$session_script")" != ok ]; then
    ss_missing="$ss_missing
  - CI, profile and identity checked before any command"
  fi
  wf_calls="$(grep -rln 'aws-session' "$workflow_dir" 2>/dev/null || true)"
  if [ -n "$wf_calls" ]; then ss_missing="$ss_missing
  - no workflow calls it (found in: $(echo $wf_calls))"; fi
  if [ -n "$ss_missing" ]; then
    bad "$session_script lost a guard that keeps plan/apply on the sandbox account:$ss_missing"
  else
    ok "$session_script keeps every sandbox guard (not in CI, no default profile, env -i, allowlist, allowed_account_ids, CONFIRM=yes, unchanged saved plan, no backend, guards first, no workflow)"
  fi
fi

# --- 9e. The emulator workflow keeps its shape (Phase 5.2c, ADR-0018):
# read-only, the emulator started by the same make target a developer
# uses (so the digest and the 127.0.0.1 binding live only in the emulator
# script), the coverage comparison, and no way around either. ------------
tf_wf=".github/workflows/terraform.yml"
if [ -f "$tf_wf" ]; then
  wf_missing=""
  wf_perms="$(awk '/^permissions:/{f=1; next} f && /^[^ ]/{exit} f && NF' "$tf_wf")"
  [ "$(printf '%s' "$wf_perms" | sed 's/[[:space:]]//g')" = "contents:read" ] || wf_missing="$wf_missing
  - workflow permissions exactly 'contents: read'"
  grep -Eq '^    permissions:' "$tf_wf" && wf_missing="$wf_missing
  - no job-level permissions"
  grep -Eq '^[[:space:]]+run: make tf-emulator-up$' "$tf_wf" || wf_missing="$wf_missing
  - starts the emulator with make tf-emulator-up"
  grep -Eq '^[[:space:]]+run: make tf-emulator-ci$' "$tf_wf" || wf_missing="$wf_missing
  - runs make tf-emulator-ci"
  grep -Eq '^[[:space:]]+services:|docker run|TF_EMULATOR_(ENDPOINT|IMAGE|STEP_TIMEOUT)|continue-on-error' "$tf_wf" && wf_missing="$wf_missing
  - no service container, docker run, emulator override or continue-on-error"
  grep -Eq '^tf-emulator-ci:' Makefile 2>/dev/null && grep -Eq "^	@bash $emulator_script ci\$" Makefile \
    || wf_missing="$wf_missing
  - Makefile target tf-emulator-ci runs $emulator_script ci"
  if [ -n "$wf_missing" ]; then
    bad "$tf_wf lost part of its shape:$wf_missing"
  else
    ok "$tf_wf is read-only and runs the emulator only through make tf-emulator-up/tf-emulator-ci"
  fi
fi

# --- 9d. Static analysis keeps its gate (Phase 5.2b, ADR-0019): the
# threshold, the failing exit code, the exception file, the embedded
# (pinned) checks only, Terraform-only scope, the stale-exception check,
# and the wiring into `make tf-static` and the validate workflow. -------
static_script="scripts/terraform/static-analysis.sh"
if [ -f "$static_script" ]; then
  st_missing=""
  st_need() { grep -Eq -- "$2" "$static_script" || st_missing="$st_missing
  - $1"; }
  st_need "threshold HIGH,CRITICAL" '^TF_STATIC_SEVERITY="HIGH,CRITICAL"$'
  st_need "exception file terraform/.trivyignore.yaml" '^TF_IGNORE_FILE="terraform/\.trivyignore\.yaml"$'
  st_need "gate fails with --exit-code 1 at the threshold" '--exit-code 1 --severity "\$TF_STATIC_SEVERITY" --ignorefile '
  st_need "embedded checks only (--skip-check-update)" '--skip-check-update'
  st_need "Terraform scanner on the tracked files" '--misconfig-scanners terraform'
  st_need "scratch copy of git-tracked files" 'git ls-files -z terraform'
  st_need "stale exceptions fail" 'holds stale exceptions'
  st_need "expired exceptions fail" 'expired on '
  grep -Eq -- '--severity (LOW|MEDIUM|UNKNOWN)|--exit-code 0' "$static_script" && st_missing="$st_missing
  - no lower threshold and no --exit-code 0 on the gate"
  grep -Eq '^tf-static:' Makefile 2>/dev/null && grep -Eq "^	@bash $static_script\$" Makefile \
    || st_missing="$st_missing
  - Makefile target tf-static runs $static_script"
  if [ -f .github/workflows/validate.yml ]; then
    grep -Eq '^[[:space:]]+run: make tf-static$' .github/workflows/validate.yml \
      || st_missing="$st_missing
  - .github/workflows/validate.yml runs make tf-static"
  fi
  if [ -n "$st_missing" ]; then
    bad "$static_script lost part of its gate:$st_missing"
  else
    ok "$static_script keeps its gate (HIGH,CRITICAL, exit 1, dated exceptions, no stale ones, pinned checks, wired into make and validate)"
  fi
fi

# --- 10. Every offline `terraform init` invocation in Makefile/*.sh
# uses -backend=false. --------------------------------------------------
init_missing_backend_false=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  case "$f" in
    *.tftest.hcl) continue ;;
  esac
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    case "$hit" in
      *-backend=false*) : ;;
      *) init_missing_backend_false="$init_missing_backend_false
$f: $hit" ;;
    esac
  done < <(grep -Ein 'terraform[^"'"'"'\n]*[[:space:]]init([[:space:]]|$)' "$f" 2>/dev/null || true)
done < <(list_versionable_files)

if [ -n "$init_missing_backend_false" ]; then
  bad "a 'terraform ... init' invocation without -backend=false was found:"
  printf '%s\n' "$init_missing_backend_false" >&2
else
  ok "every 'terraform ... init' invocation uses -backend=false"
fi

# --- 11. No real AWS account ID / role ARN anywhere under terraform/
# or .github/workflows/ (narrower, domain-specific complement to
# check-forbidden-terms.sh's project-wide 12-digit scan). Scanned via
# list_versionable_files, never a raw directory walk - a raw `grep -r
# terraform/` would also walk the gitignored .terraform/ provider
# plugin cache (a real, large compiled binary) and could spuriously
# match binary bytes that happen to look ARN-shaped, which is not this
# check's concern (that cache is never tracked in Git at all, checked
# separately below). --------------------------------------------------
real_arn_pattern='arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:'
arn_hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    terraform/*|.github/workflows/*) : ;;
    *) continue ;;
  esac
  [ -f "$f" ] || continue
  hit="$(grep -Ein "$real_arn_pattern" "$f" 2>/dev/null || true)"
  [ -n "$hit" ] && arn_hits="$arn_hits
$f:
$hit"
done < <(list_versionable_files)
if [ -n "$arn_hits" ]; then
  bad "a real-looking AWS ARN (with a 12-digit account id) was found:"
  printf '%s\n' "$arn_hits" >&2
else
  ok "no real-looking AWS ARN found under terraform/ or .github/workflows/"
fi

# --- 12. No .terraform/, .tfstate, .tfplan, .zip, or binary file is
# TRACKED in Git (gitignored is not sufficient - must actually be
# absent from the tracked/would-be-tracked set). By-name patterns first
# (.terraform/, .tfstate, .tfplan, .zip), then a generic byte-content
# scan (any NUL byte) restricted to terraform/ and .tools/ - the two
# directories this phase's own tooling writes to - so this never false-
# positives on unrelated pre-existing repository content elsewhere. ---
forbidden_tracked="$(list_versionable_files | grep -E '(^|/)\.terraform/|\.tfstate(\.[a-zA-Z0-9]+)?$|\.tfplan$|\.zip$' || true)"
if [ -n "$forbidden_tracked" ]; then
  bad ".terraform/ cache, .tfstate, .tfplan, or .zip file is tracked in Git:"
  printf '%s\n' "$forbidden_tracked" >&2
else
  ok "no .terraform/ cache, .tfstate, .tfplan, or .zip file is tracked in Git (by name)"
fi

binary_tracked=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    terraform/*|.tools/*) : ;;
    *) continue ;;
  esac
  [ -f "$f" ] || continue
  [ -s "$f" ] || continue
  if ! LC_ALL=C grep -qI '' "$f" 2>/dev/null; then
    binary_tracked="$binary_tracked
$f"
  fi
done < <(list_versionable_files)
if [ -n "$binary_tracked" ]; then
  bad "a binary (NUL-byte-containing) file is tracked under terraform/ or .tools/:"
  printf '%s\n' "$binary_tracked" >&2
else
  ok "no binary file is tracked under terraform/ or .tools/ (by content)"
fi

# --- 13. Phase 3.2: no aws_secretsmanager_secret_version resource
# anywhere, in any root, no exception, ever - unlike the resource-ban
# in check 6a (scoped to the root module only), a secret payload must
# never have a code path into Terraform state ANYWHERE in this
# repository. ------------------------------------------------------
secret_version_hits="$(grep_over_tf_files '^[[:space:]]*resource[[:space:]]*"aws_secretsmanager_secret_version"')"
if [ -n "$secret_version_hits" ]; then
  bad "an aws_secretsmanager_secret_version resource was found - a secret payload must never have a code path into Terraform state, anywhere, with no exception:"
  printf '%s\n' "$secret_version_hits" >&2
else
  ok "no aws_secretsmanager_secret_version resource exists anywhere"
fi

# --- 14. No secret_string/secret_binary argument name anywhere -
# defense in depth beyond check 13, in case a future resource type
# gains an argument with the same name. -----------------------------
payload_arg_hits="$(grep_over_tf_files '^[[:space:]]*secret_(string|binary)[[:space:]]*=')"
if [ -n "$payload_arg_hits" ]; then
  bad "a secret_string/secret_binary argument was found - no Terraform resource in this repository may ever accept a secret payload:"
  printf '%s\n' "$payload_arg_hits" >&2
else
  ok "no secret_string/secret_binary argument exists anywhere"
fi

# --- 15. No literal secretsmanager:*/kms:* action string, and no bare
# wildcard "*" as a sole IAM action, anywhere in a tracked .tf file. -
#
# Narrow, single-purpose exception (Phase 3.4.1): the region-restriction
# service control policy EXEMPTS global services from a Deny through
# NotAction - its list is AWS's documented set of global services and
# contains "kms:*" as an exemption, never as a grant. Masked ONLY: in
# exactly terraform/modules/scp/main.tf, ONLY the lines strictly inside
# the `global_actions = [ ... ]` local (the module uses that local solely
# as the NotAction of a Deny - asserted by terraform/envs/org's tests).
# Any other occurrence in that file, or the same block in any other file,
# is still rejected.
scp_global_actions_range() {
  [ -f terraform/modules/scp/main.tf ] || return 0
  awk '/^[[:space:]]*global_actions[[:space:]]*=[[:space:]]*\[[[:space:]]*$/ { s = NR; next }
       s && /^[[:space:]]*\][[:space:]]*$/ { print s + 1 " " NR - 1; exit }' terraform/modules/scp/main.tf
}
filter_scp_notaction_exemption() {
  range="$(scp_global_actions_range)"
  if [ -z "$range" ]; then cat; return 0; fi
  lo="${range% *}"; hi="${range#* }"
  awk -F: -v lo="$lo" -v hi="$hi" '!($1 == "terraform/modules/scp/main.tf" && $2 >= lo && $2 <= hi)'
}
wildcard_action_hits="$(grep_over_tf_files '"(secretsmanager|kms):\*"' | filter_scp_notaction_exemption)"
bare_star_action_hits="$(grep_over_tf_files '^[[:space:]]*actions?[[:space:]]*=[[:space:]]*(\[)?[[:space:]]*"\*"')"
if [ -n "$wildcard_action_hits" ] || [ -n "$bare_star_action_hits" ]; then
  bad "a wildcard IAM action (secretsmanager:*, kms:*, or a bare \"*\" action) was found:"
  printf '%s\n%s\n' "$wildcard_action_hits" "$bare_star_action_hits" >&2
else
  ok "no secretsmanager:*/kms:*/bare-wildcard IAM action exists anywhere"
fi

# --- 16. No aws_eks_pod_identity_association targets the webhook or
# cert-controller singleton ServiceAccount, by exact literal string,
# anywhere - these two components must never receive AWS credentials
# (.local/evidence/phase-3.2-pod-identity-secrets-manager-iac-plan.md
# S5/S6). This is a literal-string static check: a value supplied
# entirely through a variable/expression rather than a literal string
# in the .tf source is not visible to this check - the child module's
# own variable validation (terraform/modules/eso-identity/variables.tf)
# is the mechanism that actually enforces this at the Terraform-
# language level for any variable-driven value; this rule is a
# repo-wide textual backstop against a literal hardcoded regression. -
singleton_association_hits="$(grep_over_tf_files 'service_account[[:space:]]*=[[:space:]]*"external-secrets-(webhook|cert-controller)"')"
if [ -n "$singleton_association_hits" ]; then
  bad "a Pod Identity Association (or association-shaped configuration) literally targets the webhook or cert-controller singleton ServiceAccount - neither may ever receive AWS credentials:"
  printf '%s\n' "$singleton_association_hits" >&2
else
  ok "no literal Pod Identity Association targets the webhook/cert-controller singleton ServiceAccount"
fi

if [ "$fail" -ne 0 ]; then
  echo "check-terraform-offline: FAILED"
  exit 1
fi
echo "check-terraform-offline: OK"
