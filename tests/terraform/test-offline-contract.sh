#!/bin/sh
# Regression tests for scripts/validate/check-terraform-offline.sh.
# Runs the real checker, unmodified, against small, throwaway git
# repositories built under a single mktemp -d root - never against
# this repository's own tracked files. Backs
# `make check-terraform-offline-regression` only.
#
# No 40+ character hex literal and no literal 12-digit run appears
# anywhere in this source file: every fixture hash/account-shaped
# value is assembled at runtime from a short literal pattern, the same
# discipline tests/validate/test-forbidden-terms.sh already uses, so
# this test script never trips the very validators it exercises when
# the repository scans its own tracked files.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$here/scripts/validate/check-terraform-offline.sh"

if [ ! -f "$checker" ]; then
  echo "FAIL: checker not found at $checker" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "FAIL: git not found in PATH" >&2
  exit 1
fi

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM

fail=0
pass=0

report() {
  # $1=0/1 (0 pass, 1 fail)  $2=description
  if [ "$1" -eq 0 ]; then
    echo "OK: $2"
    pass=$((pass + 1))
  else
    echo "FAIL: $2" >&2
    fail=$((fail + 1))
  fi
}

hexstr() {
  count="$1"
  pattern="a1b2c3d4e5f6"
  result=""
  while [ "${#result}" -lt "$count" ]; do
    result="${result}${pattern}"
  done
  printf '%s' "$result" | cut -c "1-${count}"
}

digitstr() {
  count="$1"
  pattern="184"
  result=""
  while [ "${#result}" -lt "$count" ]; do
    result="${result}${pattern}"
  done
  printf '%s' "$result" | cut -c "1-${count}"
}

ZH_VALID="$(hexstr 64)"
H1_VALID="$(hexstr 43)="

new_case_dir() {
  d="$(mktemp -d "$root/case-XXXXXX")"
  git init -q "$d"
  printf '%s\n' "$d"
}

# Writes a fully compliant Phase 2.7.1 tree into $1: pinned versions.tf,
# a well-formed lock file, a main.tf with only the two allowlisted AWS
# data sources, a mock_provider-covered .tftest.hcl, a clean workflow,
# and a Makefile whose only terraform init is -backend=false with no
# plan/apply anywhere. Every reject case below starts from this exact
# baseline and mutates ONE thing, proving the checker's rejection is
# specific to that one mutation, not incidental.
write_good_baseline() {
  d="$1"
  mkdir -p "$d/terraform/tests" "$d/.github/workflows"

  cat > "$d/terraform/versions.tf" <<EOF
terraform {
  required_version = "= 1.16.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
EOF

  cat > "$d/terraform/.terraform.lock.hcl" <<EOF
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.63.0"
  constraints = "6.63.0"
  hashes = [
    "h1:${H1_VALID}",
    "zh:${ZH_VALID}",
  ]
}
EOF

  cat > "$d/terraform/main.tf" <<'EOF'
variable "expected_environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.expected_environment)
    error_message = "expected_environment must be exactly \"staging\" or \"production\"."
  }
}

data "aws_caller_identity" "toolchain_smoke" {}
data "aws_region" "toolchain_smoke" {}

output "toolchain_smoke_account_id" {
  value = data.aws_caller_identity.toolchain_smoke.account_id
}
EOF

  cat > "$d/terraform/tests/toolchain.tftest.hcl" <<'EOF'
mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.toolchain_smoke
    values = {
      account_id = "not-a-real-account-id"
    }
  }
}

run "plan_case" {
  command = plan
  variables {
    expected_environment = "staging"
  }
}

run "apply_case" {
  command = apply
  variables {
    expected_environment = "production"
  }
}
EOF

  cat > "$d/.github/workflows/validate.yml" <<'EOF'
name: validate
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  validate:
    runs-on: ubuntu-24.04
    steps:
      - name: make validate
        run: make validate
EOF

  cat > "$d/Makefile" <<'EOF'
.PHONY: terraform-init terraform-validate-offline

terraform-init:
	@.tools/bin/terraform -chdir=terraform init -backend=false

terraform-validate-offline:
	@.tools/bin/terraform -chdir=terraform init -backend=false
	@.tools/bin/terraform -chdir=terraform validate
	@.tools/bin/terraform -chdir=terraform test
EOF
}

# $1=directory to run the checker against (must already be its own git
# repo root, per write_good_baseline()/new_case_dir()).
run_checker() {
  ( cd "$1" && bash "$checker" )
}

# $1=description  $2=expected: accept|reject  $3=setup function name
# (receives the fixture dir as $1) applied ON TOP OF a fresh good
# baseline.
run_case() {
  desc="$1"; expected="$2"; setup_fn="$3"
  d="$(new_case_dir)"
  write_good_baseline "$d"
  "$setup_fn" "$d"

  set +e
  out="$(run_checker "$d" 2>&1)"
  rc=$?
  set -e

  case "$expected" in
    accept)
      if [ "$rc" -eq 0 ]; then
        report 0 "$desc"
      else
        report 1 "$desc - expected acceptance but checker rejected it"
        printf '%s\n' "$out"
      fi
      ;;
    reject)
      if [ "$rc" -ne 0 ]; then
        report 0 "$desc"
      else
        report 1 "$desc - expected rejection but checker accepted it"
        printf '%s\n' "$out"
      fi
      ;;
  esac
}

# --- Accept: the unmodified good baseline itself -----------------------
noop_setup() { :; }
run_case "unmodified good baseline (pinned versions, well-formed lock file, allowlisted data sources, mock_provider-covered test, clean workflow/Makefile) is accepted" \
  accept noop_setup

# --- Accept: the REAL, current Phase 2.7.1 tree from this repository ---
run_case_real_tree() {
  d="$(new_case_dir)"
  mkdir -p "$d/terraform" "$d/.github/workflows"
  cp -R "$here/terraform/." "$d/terraform/"
  rm -rf "$d/terraform/.terraform"
  cp "$here/.github/workflows/validate.yml" "$d/.github/workflows/validate.yml"
  cp "$here/Makefile" "$d/Makefile"

  set +e
  out="$(run_checker "$d" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    report 0 "the real, current Phase 2.7.1 tree (terraform/, Makefile, .github/workflows/validate.yml) is accepted"
  else
    report 1 "the real, current Phase 2.7.1 tree was rejected"
    printf '%s\n' "$out"
  fi
}
run_case_real_tree

# --- Accept: mock_provider "aws" + command = plan / command = apply ---
# (already exercised by the good baseline's own toolchain.tftest.hcl,
# which declares both a plan and an apply run block - these two cases
# isolate each one explicitly, on its own, to prove neither command
# keyword by itself is what the checker reacts to.)
setup_plan_only() {
  d="$1"
  cat > "$d/terraform/tests/toolchain.tftest.hcl" <<'EOF'
mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.toolchain_smoke
    values = { account_id = "not-a-real-account-id" }
  }
}

run "plan_only_case" {
  command = plan
  variables {
    expected_environment = "staging"
  }
}
EOF
}
run_case "a Terraform test with mock_provider \"aws\" and command = plan only is accepted" \
  accept setup_plan_only

setup_apply_only() {
  d="$1"
  cat > "$d/terraform/tests/toolchain.tftest.hcl" <<'EOF'
mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.toolchain_smoke
    values = { account_id = "not-a-real-account-id" }
  }
}

run "apply_only_case" {
  command = apply
  variables {
    expected_environment = "production"
  }
}
EOF
}
run_case "a Terraform test with mock_provider \"aws\" and command = apply only is accepted (a simulated test-framework run, never a real CLI invocation against AWS)" \
  accept setup_apply_only

# --- Reject: each of the 14 required negative cases, one mutation
# each, on top of the same good baseline. -------------------------------

setup_active_backend() {
  d="$1"
  cat > "$d/terraform/versions.tf" <<'EOF'
terraform {
  required_version = "= 1.16.1"

  backend "s3" {
    bucket = "example-bucket"
    key    = "example/terraform.tfstate"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
EOF
}
run_case "an active backend \"s3\" block is rejected" reject setup_active_backend

setup_aws_provider_not_pinned_exactly() {
  d="$1"
  sed -i.bak 's/version = "= 6.63.0"/version = "~> 6.63.0"/' "$d/terraform/versions.tf"
  rm -f "$d/terraform/versions.tf.bak"
}
run_case "an AWS provider version constraint that is not an exact pin (~> instead of =) is rejected" reject setup_aws_provider_not_pinned_exactly

setup_terraform_not_pinned_exactly() {
  d="$1"
  sed -i.bak 's/required_version = "= 1.16.1"/required_version = ">= 1.16.1"/' "$d/terraform/versions.tf"
  rm -f "$d/terraform/versions.tf.bak"
}
run_case "a Terraform required_version constraint that is not an exact pin (>= instead of =) is rejected" reject setup_terraform_not_pinned_exactly

setup_real_aws_resource() {
  d="$1"
  cat >> "$d/terraform/main.tf" <<'EOF'

resource "aws_secretsmanager_secret" "example" {
  name = "example"
}
EOF
}
run_case "a real AWS resource block (aws_secretsmanager_secret) is rejected" reject setup_real_aws_resource

setup_real_aws_data_source() {
  d="$1"
  cat >> "$d/terraform/main.tf" <<'EOF'

data "aws_vpc" "example" {
  default = true
}
EOF
}
run_case "an AWS data source not on the allowlist (aws_vpc) is rejected" reject setup_real_aws_data_source

setup_operative_aws_provider() {
  d="$1"
  cat >> "$d/terraform/main.tf" <<'EOF'

provider "aws" {
  region = "us-east-1"
}
EOF
}
run_case "an operative provider \"aws\" block in a real .tf file is rejected" reject setup_operative_aws_provider

setup_test_without_mock_provider() {
  d="$1"
  cat > "$d/terraform/tests/toolchain.tftest.hcl" <<'EOF'
run "plan_case" {
  command = plan
  variables {
    expected_environment = "staging"
  }

  assert {
    condition     = data.aws_caller_identity.toolchain_smoke.account_id != ""
    error_message = "expected a non-empty account id"
  }
}
EOF
}
run_case "a .tftest.hcl file that references aws_* without declaring mock_provider \"aws\" is rejected" reject setup_test_without_mock_provider

# The "plan"/"apply" command words below are assembled at runtime
# (never a literal substring in this source file) for the same reason
# hexstr()/digitstr() above assemble their fixture values at runtime:
# scripts/validate/check-terraform-offline.sh's own check 9 scans every
# tracked *.sh file project-wide (this file included) for a literal
# 'terraform ... plan'/'terraform ... apply' invocation - a literal
# heredoc string here would trip that checker against this repository's
# own tracked test file, exactly the false-positive-on-your-own-test-
# fixture problem tests/validate/test-forbidden-terms.sh's hexstr()/
# digitstr() helpers already exist to avoid for a different checker.
PLAN_WORD="pl""an"
APPLY_WORD="ap""ply"

setup_terraform_plan_in_makefile() {
  d="$1"
  {
    printf '\n'
    printf 'terraform-plan-real:\n'
    printf '\t@.tools/bin/terraform -chdir=terraform %s\n' "$PLAN_WORD"
  } >> "$d/Makefile"
}
run_case "a real 'terraform ... plan' invocation in the Makefile is rejected" reject setup_terraform_plan_in_makefile

setup_terraform_apply_in_makefile() {
  d="$1"
  {
    printf '\n'
    printf 'terraform-apply-real:\n'
    printf '\t@.tools/bin/terraform -chdir=terraform %s\n' "$APPLY_WORD"
  } >> "$d/Makefile"
}
run_case "a real 'terraform ... apply' invocation in the Makefile is rejected" reject setup_terraform_apply_in_makefile

setup_id_token_write() {
  d="$1"
  cat >> "$d/.github/workflows/validate.yml" <<'EOF'
permissions:
  id-token: write
EOF
}
run_case "id-token: write in a workflow is rejected" reject setup_id_token_write

setup_aws_actions() {
  d="$1"
  cat >> "$d/.github/workflows/validate.yml" <<'EOF'
      - uses: aws-actions/configure-aws-credentials@v6
EOF
}
run_case "an aws-actions/configure-aws-credentials reference in a workflow is rejected" reject setup_aws_actions

setup_aws_credential_vars() {
  d="$1"
  cat >> "$d/.github/workflows/validate.yml" <<'EOF'
env:
  AWS_ACCESS_KEY_ID: fake
  AWS_SECRET_ACCESS_KEY: fake
EOF
}
run_case "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY variables in a workflow are rejected" reject setup_aws_credential_vars

setup_tracked_tfstate() {
  d="$1"
  printf '{}' > "$d/terraform/terraform.tfstate"
}
run_case "a tracked (would-be-tracked) .tfstate file is rejected" reject setup_tracked_tfstate

setup_tracked_tfplan() {
  d="$1"
  printf 'not a real plan' > "$d/terraform/example.tfplan"
}
run_case "a tracked (would-be-tracked) .tfplan file is rejected" reject setup_tracked_tfplan

setup_tracked_zip() {
  d="$1"
  printf 'PK\x03\x04not a real zip payload' > "$d/terraform/terraform_provider.zip"
}
run_case "a tracked (would-be-tracked) .zip file is rejected" reject setup_tracked_zip

setup_tracked_binary() {
  d="$1"
  printf 'binary\000content\000here' > "$d/terraform/some-binary"
}
run_case "a tracked (would-be-tracked) binary file under terraform/ (NUL-byte content, no recognized extension) is rejected" reject setup_tracked_binary

# Same runtime-assembly reasoning as PLAN_WORD/APPLY_WORD above,
# applied to check-terraform-offline.sh's check 10 (every 'terraform
# ... init' invocation must include -backend=false).
INIT_WORD="in""it"

setup_terraform_init_without_backend_false() {
  d="$1"
  {
    printf '\n'
    printf 'terraform-init-unsafe:\n'
    printf '\t@.tools/bin/terraform -chdir=terraform %s\n' "$INIT_WORD"
  } >> "$d/Makefile"
}
run_case "a 'terraform ... init' invocation without -backend=false is rejected" reject setup_terraform_init_without_backend_false

echo ""
echo "test-offline-contract: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "test-offline-contract: FAILED"
  exit 1
fi
echo "test-offline-contract: OK"
