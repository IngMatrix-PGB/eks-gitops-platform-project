#!/bin/sh
# Prints, one per line, every Terraform root module directory this
# repository currently has: terraform/ itself, terraform/bootstrap/
# (if present), and every direct child directory of terraform/envs/.
# Purely structural, pattern-based discovery - never a manually-
# maintained list - so a newly added terraform/envs/<anything>/ is
# discovered automatically, with no registration step to forget.
#
# terraform/modules/* (reusable child modules, no state/backend of
# their own) and terraform/tests/* (shared fixtures for the root
# terraform/ module) are never matched by this rule.
#
# This is the SINGLE SOURCE OF TRUTH for "what are the Terraform root
# modules" - scripts/validate/check-terraform-offline.sh sources this
# file (via TERRAFORM_ROOT_MODULES_SOURCE_ONLY=1) to reuse the exact
# same function rather than re-implementing it, and the Makefile's
# terraform-* targets invoke this script directly to iterate over the
# same list. Never duplicate this logic elsewhere.
#
# Must be run from a repository root (relative paths: terraform/,
# terraform/bootstrap/, terraform/envs/).
set -eu

discover_terraform_root_modules() {
  printf 'terraform\n'
  [ -d terraform/bootstrap ] && printf 'terraform/bootstrap\n'
  if [ -d terraform/envs ]; then
    find terraform/envs -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
  fi
  return 0
}

# Test-only early exit: lets other scripts source this file purely for
# the function definition (e.g. to keep a single implementation) without
# also printing the real repository's discovered roots as a side
# effect - mirrors the identical INSTALL_TOOLS_SOURCE_ONLY/
# CHECK_PREREQUISITES_SOURCE_ONLY convention already used in
# scripts/lab/install-tools.sh and scripts/lab/check-prerequisites.sh.
if [ "${TERRAFORM_ROOT_MODULES_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

discover_terraform_root_modules
