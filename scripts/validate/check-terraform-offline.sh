#!/usr/bin/env bash
# Deterministic, permanent enforcement of the Phase 2.7.1 offline
# contract (.local/evidence/phase-2.7-eks-aws-foundation-plan.md):
# Terraform/AWS provider pinned exactly, a real lock file naming the
# expected provider, no active backend, no real infrastructure
# resource/data source outside a narrow documented allowlist, no
# operative `provider "aws"` block, every AWS-referencing Terraform
# test declares mock_provider "aws", no real (shell/Makefile/workflow)
# `terraform plan`/`terraform apply` invocation, no GitHub Actions
# id-token/aws-actions/AWS-credential surface, no real AWS account
# ID/role ARN, offline targets use `terraform init -backend=false`, and
# no .terraform/ cache, state, plan, zip, or binary is tracked in Git.
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

versions_tf="terraform/versions.tf"
lock_file="terraform/.terraform.lock.hcl"

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

# --- 1/2. Terraform CLI and AWS provider each pinned EXACTLY (a bare
# "=" constraint, never ~>, >=, or an unconstrained version). ---------
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

# --- 3/4. Lock file present and names the expected provider. ---------
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

# --- 5. No active backend anywhere in tracked Terraform files. -------
backend_hits="$(grep_over_tf_files '^[[:space:]]*backend[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*\{')"
if [ -n "$backend_hits" ]; then
  bad "an active backend block was found (Phase 2.7.1 must use only terraform init -backend=false, no backend configured):"
  printf '%s\n' "$backend_hits" >&2
else
  ok "no active backend block exists in any tracked .tf file"
fi

# --- 6a. Zero resource "aws_*" blocks anywhere - Phase 2.7.1 designs
# no infrastructure resource, full stop, no exception. ----------------
resource_hits="$(grep_over_tf_files '^[[:space:]]*resource[[:space:]]*"aws_[A-Za-z0-9_]+"')"
if [ -n "$resource_hits" ]; then
  bad "a real AWS resource block was found (none is authorized in Phase 2.7.1):"
  printf '%s\n' "$resource_hits" >&2
else
  ok "no AWS resource block exists in any tracked .tf file"
fi

# --- 6b. data "aws_*" blocks are allowed ONLY for the narrow,
# documented toolchain-smoke fixture (account/region identity
# introspection, read-only, no infrastructure implication) - fail
# closed on any other AWS data source type, by exact allowlist, never
# a blocklist of "known-bad" service names. -----------------------------
allowed_aws_data_sources="aws_caller_identity aws_region"
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
workflow_dir=".github/workflows"
if [ -d "$workflow_dir" ]; then
  id_token_hits="$(grep -rEn '^[[:space:]]*id-token[[:space:]]*:[[:space:]]*write' "$workflow_dir" 2>/dev/null || true)"
  if [ -n "$id_token_hits" ]; then
    bad "id-token: write found in a workflow (not authorized - no OIDC/AWS auth in Phase 2.7.1):"
    printf '%s\n' "$id_token_hits" >&2
  else
    ok "no id-token: write in any workflow"
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
plan_apply_hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  hit="$(grep -Ein "$plan_apply_pattern" "$f" 2>/dev/null || true)"
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

if [ "$fail" -ne 0 ]; then
  echo "check-terraform-offline: FAILED"
  exit 1
fi
echo "check-terraform-offline: OK"
