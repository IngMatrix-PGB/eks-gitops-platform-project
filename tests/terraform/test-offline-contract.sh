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

# Writes a correctly-pinned versions.tf + well-formed lock file at
# $1/$2 (e.g. $1="terraform/bootstrap"), mirroring the good baseline's
# own root exactly. Used by both the resource-ban-scoping cases and the
# multi-root-discovery cases below.
write_valid_child_root() {
  base_dir="$1"; rel="$2"
  mkdir -p "$base_dir/$rel"
  cat > "$base_dir/$rel/versions.tf" <<EOF
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
  cat > "$base_dir/$rel/.terraform.lock.hcl" <<EOF
provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.63.0"
  constraints = "6.63.0"
  hashes = [
    "h1:${H1_VALID}",
    "zh:${ZH_VALID}",
  ]
}
EOF
}

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
    condition     = contains(["uat", "prod"], var.expected_environment)
    error_message = "expected_environment must be exactly \"uat\" or \"prod\"."
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
    expected_environment = "uat"
  }
}

run "apply_case" {
  command = apply
  variables {
    expected_environment = "prod"
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
  # Every root module now has its own gitignored .terraform/ provider/
  # module cache (terraform/, terraform/bootstrap/, terraform/envs/*/,
  # Phase 3.1) - remove all of them, not just the top-level one, since
  # none is ever tracked in Git and this fixture must mirror exactly
  # what list_versionable_files() would see in the real repository.
  find "$d/terraform" -name '.terraform' -type d -prune -exec rm -rf {} +
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
    expected_environment = "uat"
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
    expected_environment = "prod"
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
run_case "a configured backend \"s3\" block (real bucket/key/region) is rejected" reject setup_active_backend

# Phase 3.1: an empty/partial backend declaration is explicitly
# allowed - the real bucket/key/region are supplied later via
# -backend-config at a real, future, separately-authorized `terraform
# init`, never hardcoded now.
setup_empty_backend_one_line() {
  d="$1"
  cat > "$d/terraform/versions.tf" <<'EOF'
terraform {
  required_version = "= 1.16.1"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
EOF
}
run_case "an empty backend \"s3\" {} block (single line) is accepted" accept setup_empty_backend_one_line

setup_empty_backend_multiline() {
  d="$1"
  cat > "$d/terraform/versions.tf" <<'EOF'
terraform {
  required_version = "= 1.16.1"

  backend "s3" {
    # bucket/key/region supplied later via -backend-config
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
run_case "an empty backend \"s3\" block (multi-line, comment/blank only) is accepted" accept setup_empty_backend_multiline

setup_backend_with_one_real_attribute() {
  d="$1"
  cat > "$d/terraform/versions.tf" <<'EOF'
terraform {
  required_version = "= 1.16.1"

  backend "s3" {
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
run_case "a backend block with even one real attribute (region only) is rejected" reject setup_backend_with_one_real_attribute

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
run_case "a real AWS resource block (aws_secretsmanager_secret) in the root terraform/ module is rejected" reject setup_real_aws_resource

# Phase 3.1: the resource ban is scoped to the root terraform/ module
# only - bootstrap/ and envs/*/ are the authorized locations for real
# (never-applied) AWS resource blocks.
setup_real_aws_resource_in_bootstrap() {
  d="$1"
  write_valid_child_root "$d" "terraform/bootstrap"
  cat > "$d/terraform/bootstrap/main.tf" <<'EOF'
resource "aws_s3_bucket" "terraform_state" {
  bucket        = "example-state-bucket"
  force_destroy = false
}
EOF
}
run_case "a real AWS resource block (aws_s3_bucket) in terraform/bootstrap/ is accepted" \
  accept setup_real_aws_resource_in_bootstrap

setup_real_aws_resource_in_envs_network() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/network"
  cat > "$d/terraform/envs/network/main.tf" <<'EOF'
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
}

variable "vpc_cidr" {
  type = string
}
EOF
}
run_case "a real AWS resource block (aws_vpc) in terraform/envs/network/ is accepted" \
  accept setup_real_aws_resource_in_envs_network

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
    expected_environment = "uat"
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

# Phase 5.1b: the Sigstore exception is image.yml only - a lookalike name
# is still rejected.
setup_id_token_write_lookalike() {
  d="$1"
  cat > "$d/.github/workflows/image-sign.yml" <<'EOF'
permissions:
  id-token: write
EOF
}
run_case "id-token: write in a workflow other than image.yml is rejected" reject setup_id_token_write_lookalike

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

# --- Phase 3.1: multi-root-module discovery. discover_terraform_root_
# modules() finds terraform/ itself, terraform/bootstrap/, and every
# direct child of terraform/envs/ - by directory structure, never a
# manually-maintained list. These cases prove: (a) multiple correctly-
# pinned roots are all accepted together, (b) a failure in exactly one
# root is reported without being masked by the others passing, and (c)
# critically, a root module the checker has never been told about by
# name - a brand-new terraform/envs/<anything>/ - is still discovered
# and enforced, proving a newly added root cannot silently bypass
# validation. -----------------------------------------------------------

setup_multiple_valid_roots() {
  d="$1"
  write_valid_child_root "$d" "terraform/bootstrap"
  write_valid_child_root "$d" "terraform/envs/network"
  write_valid_child_root "$d" "terraform/envs/eks"
}
run_case "terraform/bootstrap, terraform/envs/network, and terraform/envs/eks, all correctly pinned, are accepted together" \
  accept setup_multiple_valid_roots

setup_one_root_missing_lockfile_among_several() {
  d="$1"
  write_valid_child_root "$d" "terraform/bootstrap"
  write_valid_child_root "$d" "terraform/envs/network"
  write_valid_child_root "$d" "terraform/envs/eks"
  rm -f "$d/terraform/envs/eks/.terraform.lock.hcl"
}
run_case "a missing lock file in exactly one of several discovered roots (envs/eks) is rejected, not masked by the other roots being valid" \
  reject setup_one_root_missing_lockfile_among_several

setup_one_root_bad_pin_among_several() {
  d="$1"
  write_valid_child_root "$d" "terraform/bootstrap"
  write_valid_child_root "$d" "terraform/envs/network"
  write_valid_child_root "$d" "terraform/envs/eks"
  sed -i.bak 's/version = "= 6.63.0"/version = "~> 6.63.0"/' "$d/terraform/envs/network/versions.tf"
  rm -f "$d/terraform/envs/network/versions.tf.bak"
}
run_case "a non-exact AWS provider pin in exactly one of several discovered roots (envs/network) is rejected, not masked by the other roots being valid" \
  reject setup_one_root_bad_pin_among_several

# The decisive case: a root module this checker's source code never
# names anywhere (terraform/envs/some-future-root, not network/eks/
# bootstrap) is still discovered purely by directory structure and
# still fails on its own bad pin - proving discovery is structural, not
# a hardcoded list that a genuinely new root could slip past silently.
setup_previously_unknown_root_with_bad_pin() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/some-future-root-never-named-in-the-checker"
  sed -i.bak 's/required_version = "= 1.16.1"/required_version = ">= 1.16.1"/' \
    "$d/terraform/envs/some-future-root-never-named-in-the-checker/versions.tf"
  rm -f "$d/terraform/envs/some-future-root-never-named-in-the-checker/versions.tf.bak"
}
run_case "a brand-new, previously unknown terraform/envs/<name>/ root with a bad pin is still discovered and rejected (adding a root cannot silently bypass validation)" \
  reject setup_previously_unknown_root_with_bad_pin

setup_previously_unknown_root_valid() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/some-future-root-never-named-in-the-checker"
}
run_case "a brand-new, previously unknown terraform/envs/<name>/ root that is correctly pinned is accepted" \
  accept setup_previously_unknown_root_valid

# --- Phase 3.2: aws_iam_policy_document is now allowed (a zero-AWS-
# contact, purely local data source), while aws_availability_zones
# remains explicitly rejected (a real AWS API call, deliberately never
# added to the allowlist per instruction). ------------------------------

setup_iam_policy_document_data_source() {
  d="$1"
  cat >> "$d/terraform/main.tf" <<'EOF'

data "aws_iam_policy_document" "example" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:us-east-1:aws:secret:example"]
  }
}
EOF
}
run_case "an aws_iam_policy_document data source is accepted (zero AWS contact, purely local JSON rendering)" \
  accept setup_iam_policy_document_data_source

setup_availability_zones_data_source_still_rejected() {
  d="$1"
  cat >> "$d/terraform/main.tf" <<'EOF'

data "aws_availability_zones" "example" {}
EOF
}
run_case "an aws_availability_zones data source remains rejected (a real AWS API call, deliberately never allowlisted)" \
  reject setup_availability_zones_data_source_still_rejected

# --- Phase 3.2: no aws_secretsmanager_secret_version anywhere, no
# secret_string/secret_binary argument anywhere, no matter which root -
# a stricter, no-exception ban than the root-scoped resource ban above.

setup_secret_version_in_bootstrap() {
  d="$1"
  write_valid_child_root "$d" "terraform/bootstrap"
  cat > "$d/terraform/bootstrap/main.tf" <<'EOF'
resource "aws_secretsmanager_secret" "example" {
  name = "example"
}

resource "aws_secretsmanager_secret_version" "example" {
  secret_id     = aws_secretsmanager_secret.example.id
  secret_string = "not-a-real-value"
}
EOF
}
run_case "an aws_secretsmanager_secret_version resource is rejected even inside an otherwise-authorized root (bootstrap/)" \
  reject setup_secret_version_in_bootstrap

setup_secret_binary_argument() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/network"
  cat > "$d/terraform/envs/network/main.tf" <<'EOF'
resource "aws_secretsmanager_secret" "example" {
  name = "example"
}

resource "aws_ssm_parameter" "example" {
  name        = "example"
  type        = "SecureString"
  secret_binary = "not-a-real-value"
}
EOF
}
run_case "a secret_binary argument is rejected regardless of which resource type carries it" \
  reject setup_secret_binary_argument

# --- Phase 3.2: no secretsmanager:*/kms:*/bare-wildcard IAM action
# anywhere, no matter which root. ---------------------------------------

setup_secretsmanager_wildcard_action() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat > "$d/terraform/envs/identity/main.tf" <<'EOF'
data "aws_iam_policy_document" "example" {
  statement {
    actions   = ["secretsmanager:*"]
    resources = ["arn:aws:secretsmanager:us-east-1:aws:secret:example"]
  }
}
EOF
}
run_case "a secretsmanager:* wildcard action is rejected" \
  reject setup_secretsmanager_wildcard_action

setup_kms_wildcard_action() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat > "$d/terraform/envs/identity/main.tf" <<'EOF'
data "aws_iam_policy_document" "example" {
  statement {
    actions   = ["kms:*"]
    resources = ["arn:aws:kms:us-east-1:aws:key/example"]
  }
}
EOF
}
run_case "a kms:* wildcard action is rejected" \
  reject setup_kms_wildcard_action

# --- Phase 3.4.1: the region SCP's NotAction exemption list -------------
setup_scp_notaction_exemption_accepted() {
  d="$1"
  mkdir -p "$d/terraform/modules/scp"
  cat > "$d/terraform/modules/scp/main.tf" <<'EOF'
locals {
  global_actions = [
    "iam:*", "kms:*", "sts:*",
  ]
  region_guardrail = {
    Statement = [{ Effect = "Deny", NotAction = local.global_actions, Resource = "*" }]
  }
}
EOF
}
run_case "kms:* inside the region SCP's global_actions NotAction list (terraform/modules/scp/main.tf) is accepted" \
  accept setup_scp_notaction_exemption_accepted

setup_scp_kms_outside_exemption() {
  d="$1"
  mkdir -p "$d/terraform/modules/scp"
  cat > "$d/terraform/modules/scp/main.tf" <<'EOF'
locals {
  global_actions = [
    "iam:*", "sts:*",
  ]
  other_actions = ["kms:*"]
}
EOF
}
run_case "kms:* anywhere else in terraform/modules/scp/main.tf is still rejected" \
  reject setup_scp_kms_outside_exemption

setup_scp_exemption_shape_elsewhere() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat >> "$d/terraform/envs/identity/main.tf" <<'EOF'
locals {
  global_actions = [
    "kms:*",
  ]
}
EOF
}
run_case "the same global_actions shape in any other file is still rejected" \
  reject setup_scp_exemption_shape_elsewhere

setup_bare_star_action() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat > "$d/terraform/envs/identity/main.tf" <<'EOF'
data "aws_iam_policy_document" "example" {
  statement {
    actions   = ["*"]
    resources = ["arn:aws:secretsmanager:us-east-1:aws:secret:example"]
  }
}
EOF
}
run_case "a bare wildcard \"*\" action is rejected" \
  reject setup_bare_star_action

setup_enumerated_actions_accepted() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat > "$d/terraform/envs/identity/main.tf" <<'EOF'
data "aws_iam_policy_document" "example" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:us-east-1:aws:secret:example"]
  }
}
EOF
}
run_case "enumerated, specific IAM actions (never a wildcard) are accepted" \
  accept setup_enumerated_actions_accepted

# --- Phase 3.2: no Pod Identity Association literally targets the
# webhook/cert-controller singleton ServiceAccount, no matter which
# root. -------------------------------------------------------------

setup_association_targets_webhook() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat > "$d/terraform/envs/identity/main.tf" <<'EOF'
resource "aws_eks_pod_identity_association" "example" {
  cluster_name    = "example"
  namespace       = "eso-uat"
  service_account = "external-secrets-webhook"
  role_arn        = "arn:aws:iam::aws:role/example"
}
EOF
}
run_case "a Pod Identity Association literally targeting the webhook ServiceAccount is rejected" \
  reject setup_association_targets_webhook

setup_association_targets_cert_controller() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat > "$d/terraform/envs/identity/main.tf" <<'EOF'
resource "aws_eks_pod_identity_association" "example" {
  cluster_name    = "example"
  namespace       = "eso-uat"
  service_account = "external-secrets-cert-controller"
  role_arn        = "arn:aws:iam::aws:role/example"
}
EOF
}
run_case "a Pod Identity Association literally targeting the cert-controller ServiceAccount is rejected" \
  reject setup_association_targets_cert_controller

setup_association_targets_real_controller_accepted() {
  d="$1"
  write_valid_child_root "$d" "terraform/envs/identity"
  cat > "$d/terraform/envs/identity/main.tf" <<'EOF'
resource "aws_eks_pod_identity_association" "example" {
  cluster_name    = "example"
  namespace       = "eso-uat"
  service_account = "eso-uat-external-secrets"
  role_arn        = "arn:aws:iam::aws:role/example"
}
EOF
}
run_case "a Pod Identity Association targeting the real ESO controller ServiceAccount is accepted" \
  accept setup_association_targets_real_controller_accepted

# --- Phase 5.2a (ADR-0018): the emulator exception -----------------------
# The real scripts/terraform/emulator.sh is copied into the fixture; each
# reject case removes exactly one guard from that copy.
EMU_SRC="$here/scripts/terraform/emulator.sh"
put_emulator() {
  mkdir -p "$1/scripts/terraform"
  cp "$EMU_SRC" "$1/scripts/terraform/emulator.sh"
}
# $1=fixture  $2=sed expression applied to the copy; the case fails loudly
# if the expression changed nothing (a no-op mutation proves nothing).
mutate_emulator() {
  put_emulator "$1"
  f="$1/scripts/terraform/emulator.sh"
  cp "$f" "$f.orig"
  sed -i.bak -e "$2" "$f" && rm -f "$f.bak"
  if cmp -s "$f" "$f.orig"; then
    echo "FAIL: emulator mutation '$2' changed nothing" >&2
    exit 1
  fi
  rm -f "$f.orig"
}
setup_emulator_real() {
  put_emulator "$1"
  printf '\ntf-emulator-x:\n\t@bash scripts/terraform/emulator.sh %s\n' "$PLAN_WORD" >> "$1/Makefile"
}
run_case "the real emulator script, and a Makefile target that calls it with '$PLAN_WORD', are accepted" accept setup_emulator_real

setup_emulator_no_allowed_accounts() { mutate_emulator "$1" '/allowed_account_ids/d'; }
run_case "the emulator script without allowed_account_ids is rejected" reject setup_emulator_no_allowed_accounts
setup_emulator_remote_default() { mutate_emulator "$1" 's#:-http://localhost:5050#:-http://emulator.example.invalid:5050#'; }
run_case "the emulator script with a non-loopback default endpoint is rejected" reject setup_emulator_remote_default
setup_emulator_no_loopback_check() { mutate_emulator "$1" 's#http://127.0.0.1:\[0-9\]\*|http://localhost:\[0-9\]\*) : ;;#*) : ;;#'; }
run_case "the emulator script without its loopback-only endpoint check is rejected" reject setup_emulator_no_loopback_check
setup_emulator_no_env_i() { mutate_emulator "$1" 's#^  env -i \\$#  env \\#'; }
run_case "the emulator script running terraform without env -i is rejected" reject setup_emulator_no_env_i
setup_emulator_aws_config() { mutate_emulator "$1" 's#AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null##'; }
run_case "the emulator script that lets the caller's AWS config through is rejected" reject setup_emulator_aws_config
setup_emulator_unpinned_image() { mutate_emulator "$1" 's#@sha256:[0-9a-f]*"$#"#'; }
run_case "the emulator script with an image not pinned by digest is rejected" reject setup_emulator_unpinned_image
setup_emulator_one_endpoint() { mutate_emulator "$1" 's#for s in \$EMULATOR_SERVICES; do#for s in s3; do#'; }
run_case "the emulator script that sends only some services to the emulator is rejected" reject setup_emulator_one_endpoint
setup_emulator_no_identity() { mutate_emulator "$1" '/^  plan|apply|coverage|ci)/,/run_root/{/^    check_identity$/d;}'; }
run_case "the emulator script that skips the identity check before plan/apply is rejected" reject setup_emulator_no_identity
setup_emulator_backend() { mutate_emulator "$1" 's#init -backend=false#init -backend-config=bucket=x#'; }
run_case "the emulator script with a backend configuration is rejected" reject setup_emulator_backend

setup_other_script_plan() {
  mkdir -p "$1/scripts"
  printf '#!/bin/sh\n.tools/bin/terraform -chdir=terraform %s\n' "$PLAN_WORD" > "$1/scripts/other.sh"
}
run_case "a 'terraform ... $PLAN_WORD' in any other script is still rejected" reject setup_other_script_plan
setup_other_script_named_like_emulator() {
  mkdir -p "$1/scripts/terraform"
  printf '#!/bin/sh\n.tools/bin/terraform -chdir=terraform %s # scripts/terraform/emulator.sh\n' "$APPLY_WORD" > "$1/scripts/terraform/emulator2.sh"
}
run_case "naming the emulator script on a line does not exempt a real '$APPLY_WORD'" reject setup_other_script_named_like_emulator
setup_other_script_writes_provider() {
  mkdir -p "$1/scripts"
  printf '#!/bin/sh\necho %s > x.tf\n' "'provider \"aws\" {'" > "$1/scripts/gen.sh"
}
run_case "another script that writes a provider \"aws\" block is rejected" reject setup_other_script_writes_provider

# --- Phase 6.4a (ADR-0024): the sandbox-session exception, check 9f ------
# The real scripts/terraform/aws-session.sh is copied into the fixture;
# each reject case removes exactly one guard from that copy.
SESSION_SRC="$here/scripts/terraform/aws-session.sh"
put_session() {
  mkdir -p "$1/scripts/terraform"
  cp "$SESSION_SRC" "$1/scripts/terraform/aws-session.sh"
}
mutate_session() {
  put_session "$1"
  f="$1/scripts/terraform/aws-session.sh"
  cp "$f" "$f.orig"
  sed -i.bak -e "$2" "$f" && rm -f "$f.bak"
  if cmp -s "$f" "$f.orig"; then
    echo "FAIL: session mutation '$2' changed nothing" >&2
    exit 1
  fi
  rm -f "$f.orig"
}
setup_session_real() {
  put_session "$1"
  printf '\neks-session-x:\n\t@bash scripts/terraform/aws-session.sh %s budget\n' "$APPLY_WORD" >> "$1/Makefile"
}
run_case "the real session script, and a Makefile target that calls it with '$APPLY_WORD', are accepted" accept setup_session_real
setup_session_ci() { mutate_session "$1" '/^  \[ -z "\${CI:-}\${GITHUB_ACTIONS:-}" \] || fail/d'; }
run_case "the session script that may run in CI is rejected" reject setup_session_ci
setup_session_default_profile() { mutate_session "$1" '/^  \[ "\$AWS_PROFILE" != "default" \] || fail/d'; }
run_case "the session script that accepts the default profile is rejected" reject setup_session_default_profile
setup_session_no_env_i() { mutate_session "$1" 's#^  env -i \\$#  env \\#'; }
run_case "the session script running aws/terraform without env -i is rejected" reject setup_session_no_env_i
setup_session_no_allowlist() { mutate_session "$1" 's#grep -qx "\$acct" "\$SESSION_ALLOWLIST" || fail#true || fail#'; }
run_case "the session script that skips the account allowlist is rejected" reject setup_session_no_allowlist
setup_session_no_allowed_accounts() { mutate_session "$1" '/allowed_account_ids = /d'; }
run_case "the session script without allowed_account_ids is rejected" reject setup_session_no_allowed_accounts
setup_session_no_confirm() { mutate_session "$1" 's#\[ "\${CONFIRM:-}" = "yes" \] || fail#true || fail#'; }
run_case "the session script without CONFIRM=yes is rejected" reject setup_session_no_confirm
setup_session_stale_plan() { mutate_session "$1" 's#\[ "\$(inputs_sha "\$stack")" = "\$(cat "\$work/plan.sha")" \] || fail#true || fail#'; }
run_case "the session script that applies a stale saved plan is rejected" reject setup_session_stale_plan
setup_session_backend() { mutate_session "$1" 's#init -backend=false#init -backend-config=bucket=x#'; }
run_case "the session script with a backend configuration is rejected" reject setup_session_backend
setup_session_late_identity() { mutate_session "$1" '/^check_identity$/d'; }
run_case "the session script that dispatches before the identity check is rejected" reject setup_session_late_identity
setup_session_workflow() {
  put_session "$1"
  printf '\n      - run: bash scripts/terraform/aws-session.sh sweep\n' >> "$1/.github/workflows/validate.yml"
}
run_case "a workflow that calls the session script is rejected" reject setup_session_workflow

# --- Phase 5.2b (ADR-0019): check 9d, the static-analysis gate. ---------
STATIC_SRC="$here/scripts/terraform/static-analysis.sh"
put_static() {
  mkdir -p "$1/scripts/terraform"
  cp "$STATIC_SRC" "$1/scripts/terraform/static-analysis.sh"
  printf '\ntf-static:\n\t@bash scripts/terraform/static-analysis.sh\n' >> "$1/Makefile"
  printf '\n      - name: make tf-static\n        run: make tf-static\n' >> "$1/.github/workflows/validate.yml"
}
# $1=fixture  $2=sed expression on the copied script; a no-op fails loudly.
mutate_static() {
  put_static "$1"
  f="$1/scripts/terraform/static-analysis.sh"
  cp "$f" "$f.orig"
  sed -i.bak -e "$2" "$f" && rm -f "$f.bak"
  if cmp -s "$f" "$f.orig"; then
    echo "FAIL: static mutation '$2' changed nothing" >&2
    exit 1
  fi
  rm -f "$f.orig"
}
setup_static_real() { put_static "$1"; }
run_case "the real static-analysis script, wired into make and validate, is accepted" accept setup_static_real
setup_static_low_threshold() { mutate_static "$1" 's#^TF_STATIC_SEVERITY="HIGH,CRITICAL"$#TF_STATIC_SEVERITY="CRITICAL"#'; }
run_case "the static-analysis script with a threshold above HIGH is rejected" reject setup_static_low_threshold
setup_static_no_exit_code() { mutate_static "$1" 's#--exit-code 1 --severity#--severity#'; }
run_case "the static-analysis gate without --exit-code 1 is rejected" reject setup_static_no_exit_code
setup_static_exit_zero() { mutate_static "$1" 's#^repo="\$(pwd)"$#repo="$(pwd)"; extra="--exit-code 0"#'; }
run_case "the static-analysis script that adds --exit-code 0 is rejected" reject setup_static_exit_zero
setup_static_check_update() { mutate_static "$1" 's#--skip-check-update ##'; }
run_case "the static-analysis script that downloads a newer rule bundle is rejected" reject setup_static_check_update
setup_static_no_stale() { mutate_static "$1" '/holds stale exceptions/d'; }
run_case "the static-analysis script without the stale-exception check is rejected" reject setup_static_no_stale
setup_static_no_make() {
  put_static "$1"
  sed -i.bak '/^tf-static:/,/static-analysis.sh/d' "$1/Makefile" && rm -f "$1/Makefile.bak"
}
run_case "the static-analysis script without its make tf-static target is rejected" reject setup_static_no_make
setup_static_no_ci() {
  put_static "$1"
  sed -i.bak '/run: make tf-static/d' "$1/.github/workflows/validate.yml" && rm -f "$1/.github/workflows/validate.yml.bak"
}
run_case "the static-analysis script not run by the validate workflow is rejected" reject setup_static_no_ci

# --- Phase 5.2c (ADR-0018): check 9e, the emulator workflow, and the ci
# comparison kept by check 9b. ------------------------------------------
TFWF_SRC="$here/.github/workflows/terraform.yml"
put_tfwf() {
  cp "$TFWF_SRC" "$1/.github/workflows/terraform.yml"
  printf '\ntf-emulator-ci:\n\t@bash scripts/terraform/emulator.sh ci\n' >> "$1/Makefile"
}
# $1=fixture  $2=sed expression on the copied workflow; a no-op fails loudly.
mutate_tfwf() {
  put_tfwf "$1"
  f="$1/.github/workflows/terraform.yml"
  cp "$f" "$f.orig"
  sed -i.bak -e "$2" "$f" && rm -f "$f.bak"
  if cmp -s "$f" "$f.orig"; then
    echo "FAIL: workflow mutation '$2' changed nothing" >&2
    exit 1
  fi
  rm -f "$f.orig"
}
setup_tfwf_real() { put_tfwf "$1"; }
run_case "the real emulator workflow, with its make tf-emulator-ci target, is accepted" accept setup_tfwf_real
setup_tfwf_write() { mutate_tfwf "$1" 's#^  contents: read$#  contents: write#'; }
run_case "the emulator workflow with write permissions is rejected" reject setup_tfwf_write
setup_tfwf_id_token() { mutate_tfwf "$1" 's#^  contents: read$#  contents: read\n  id-token: write#'; }
run_case "the emulator workflow with an OIDC token is rejected" reject setup_tfwf_id_token
setup_tfwf_job_perms() { mutate_tfwf "$1" 's#^    runs-on: ubuntu-24.04$#    runs-on: ubuntu-24.04\n    permissions:\n      contents: read#'; }
run_case "the emulator workflow with job-level permissions is rejected" reject setup_tfwf_job_perms
setup_tfwf_no_ci() { mutate_tfwf "$1" '/run: make tf-emulator-ci$/d'; }
run_case "the emulator workflow that does not run make tf-emulator-ci is rejected" reject setup_tfwf_no_ci
setup_tfwf_services() { mutate_tfwf "$1" 's#^    timeout-minutes: 30$#    timeout-minutes: 30\n    services:\n      moto:\n        image: moto#'; }
run_case "the emulator workflow with its own service container is rejected" reject setup_tfwf_services
setup_tfwf_endpoint() { mutate_tfwf "$1" 's#^        run: make tf-emulator-ci$#        run: TF_EMULATOR_ENDPOINT=http://localhost:9 make tf-emulator-ci#'; }
run_case "the emulator workflow that overrides the emulator endpoint is rejected" reject setup_tfwf_endpoint
setup_tfwf_continue() { mutate_tfwf "$1" 's#^      - name: make tf-emulator-ci$#      - name: make tf-emulator-ci\n        continue-on-error: true#'; }
run_case "the emulator workflow that tolerates a failed comparison is rejected" reject setup_tfwf_continue
setup_tfwf_no_make() {
  cp "$TFWF_SRC" "$1/.github/workflows/terraform.yml"
}
run_case "the emulator workflow without the make tf-emulator-ci target is rejected" reject setup_tfwf_no_make
setup_emulator_no_compare() { mutate_emulator "$1" 's#rc=0; compare_coverage || rc=1#rc=0#'; }
run_case "the emulator script whose ci mode skips the coverage comparison is rejected" reject setup_emulator_no_compare

echo ""
echo "test-offline-contract: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "test-offline-contract: FAILED"
  exit 1
fi
echo "test-offline-contract: OK"
