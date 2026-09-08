#!/bin/sh
# Regression tests for scripts/validate/check-forbidden-terms.sh's
# narrow GitHub-Actions checkout-SHA-pin exception. Runs the real
# validator against small, throwaway git repositories built under a
# single mktemp -d root - never against this repository's own tracked
# files. Backs `make check-forbidden-terms-regression` only.
#
# No 40-character (or longer) hex literal appears anywhere in this
# source file: every fixture SHA-shaped value is assembled at runtime
# from a short literal pattern (well under any restricted-pattern
# threshold), so this test script does not trip the very validator it
# exercises when the repository scans its own tracked files.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
validator="$here/scripts/validate/check-forbidden-terms.sh"

if [ ! -f "$validator" ]; then
  echo "FAIL: validator not found at $validator" >&2
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

# Builds a fixed-length hex string at runtime from a short literal
# pattern (12 hex characters), repeated and truncated to length.
hexstr() {
  count="$1"
  pattern="a1b2c3d4e5f6"
  result=""
  while [ "${#result}" -lt "$count" ]; do
    result="${result}${pattern}"
  done
  printf '%s' "$result" | cut -c "1-${count}"
}

SHA1="$(hexstr 40)"
SHA256="$(hexstr 64)"
HEX39="$(hexstr 39)"
HEX41="$(hexstr 41)"

# Builds a fixed-length, purely-numeric string at runtime from a short
# literal pattern (3 digits - never itself a 12+ digit run in this
# source file, even where the pattern name is repeated on one line),
# the same way hexstr() above avoids ever writing a real hex secret
# literal. Used to build AWS-account-ID-shaped (or longer) digit runs
# without ever putting one directly in this file's source.
digitstr() {
  count="$1"
  pattern="184"
  result=""
  while [ "${#result}" -lt "$count" ]; do
    result="${result}${pattern}"
  done
  printf '%s' "$result" | cut -c "1-${count}"
}

AWS12="$(digitstr 12)"
# A well-formed 64-hex-character value that is ALL digits - trivially
# contains (and is entirely made of) a 12+ digit run, while still being
# a syntactically valid SHA256-shaped hex string (digits are valid hex
# digits too).
CHK_WITH_DIGITS="$(digitstr 64)"
# A well-formed 64-hex-character value with no 12-digit run at all
# (hexstr()'s letter/digit-alternating pattern never repeats a digit
# twice in a row) - the "legitimate checksum, nothing to flag" fixture.
CHK_VALID="$SHA256"

new_case_dir() {
  # mktemp -d guarantees a fresh, unique directory on every call -
  # deliberately not a counter variable incremented inside this
  # function: the function is always invoked as `d="$(new_case_dir)"`,
  # which runs it in a subshell, so any assignment to a shell variable
  # here would be silently lost the moment that subshell exits.
  d="$(mktemp -d "$root/case-XXXXXX")"
  git init -q "$d"
  printf '%s\n' "$d"
}

# $1 = description  $2 = expected: reject|accept  $3 = relative file path  $4 = file content
run_case() {
  desc="$1"; expected="$2"; relpath="$3"; content="$4"
  d="$(new_case_dir)"
  mkdir -p "$d/$(dirname "$relpath")"
  printf '%s' "$content" > "$d/$relpath"

  set +e
  out="$(cd "$d" && bash "$validator" 2>&1)"
  rc=$?
  set -e

  case "$expected" in
    reject)
      if [ "$rc" -ne 0 ]; then
        echo "PASS: $desc (correctly rejected)"
        pass=$((pass + 1))
      else
        echo "FAIL: $desc - expected rejection but the validator passed"
        printf '%s\n' "$out"
        fail=$((fail + 1))
      fi
      ;;
    accept)
      if [ "$rc" -eq 0 ]; then
        echo "PASS: $desc (correctly accepted)"
        pass=$((pass + 1))
      else
        echo "FAIL: $desc - expected acceptance but the validator rejected it"
        printf '%s\n' "$out"
        fail=$((fail + 1))
      fi
      ;;
  esac
}

# --- Must be rejected ---------------------------------------------------

run_case "bare 40-hex token in a Markdown file" reject \
  "notes.md" "Some notes with a token ${SHA1} embedded.
"

run_case "bare 40-hex token in a shell script" reject \
  "script.sh" "#!/bin/sh
echo ${SHA1}
"

run_case "commit=<40-hex>" reject \
  "notes.txt" "commit=${SHA1}
"

run_case "40-hex token in a workflow comment" reject \
  ".github/workflows/other1.yml" "# pinned to ${SHA1}
name: other1
"

run_case "40-hex token under run:" reject \
  ".github/workflows/other2.yml" "jobs:
  x:
    steps:
      - run: echo ${SHA1}
"

run_case "40-hex token under env:" reject \
  ".github/workflows/other3.yml" "env:
  FOO: ${SHA1}
"

run_case "actions/checkout@<40-hex> outside .github/workflows/" reject \
  "docs/notes.yml" "uses: actions/checkout@${SHA1}
"

run_case "arbitrary owner/action@<40-hex> workflow reference" reject \
  ".github/workflows/other4.yml" "jobs:
  x:
    steps:
      - uses: someorg/someaction@${SHA1}
"

run_case "checkout pin with an inline comment" reject \
  ".github/workflows/other5.yml" "jobs:
  x:
    steps:
      - uses: actions/checkout@${SHA1} # pinned
"

run_case "checkout pin with trailing suffix text" reject \
  ".github/workflows/other6.yml" "jobs:
  x:
    steps:
      - uses: actions/checkout@${SHA1}-extra
"

# --- Must be accepted ----------------------------------------------------

real_workflow="$here/.github/workflows/validate.yml"
if [ ! -f "$real_workflow" ]; then
  echo "FAIL: real workflow not found at $real_workflow - cannot run the pinned-line acceptance case" >&2
  fail=$((fail + 1))
else
  d="$(new_case_dir)"
  mkdir -p "$d/.github/workflows"
  cp "$real_workflow" "$d/.github/workflows/validate.yml"
  set +e
  out="$(cd "$d" && bash "$validator" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "PASS: the real .github/workflows/validate.yml is accepted as-is (exact pinned checkout line)"
    pass=$((pass + 1))
  else
    echo "FAIL: the real .github/workflows/validate.yml was rejected"
    printf '%s\n' "$out"
    fail=$((fail + 1))
  fi
fi

run_case "well-formed actions/checkout@<40-hex> pin (synthetic SHA)" accept \
  ".github/workflows/synthetic.yml" "jobs:
  x:
    steps:
      - name: Checkout
        uses: actions/checkout@${SHA1}
"

run_case "bare 64-character SHA256-shaped digest" accept \
  "notes.md" "digest ${SHA256} end
"

run_case "repo@sha256:<64-hex>" accept \
  "values.yaml" "image:
  repository: example.invalid/repo
  tag: \"v1.0.0@sha256:${SHA256}\"
"

run_case "39-character hex string (not 40)" accept \
  "notes.md" "token ${HEX39} end
"

run_case "41-character hex string (not 40)" accept \
  "notes.md" "token ${HEX41} end
"

# --- scripts/lab/tool-versions.txt's narrow aws_account_pattern
# exception: masks ONLY fields 7 and 8 (download_sha256,
# installed_sha256), ONLY when each is exactly a well-formed 64-hex
# value, ONLY at this exact path. -------------------------------------

run_case "AWS-account-ID-shaped digit run inside download_sha256 (field 7)" accept \
  "scripts/lab/tool-versions.txt" \
  "kind|v0.33.0|linux-amd64|kind|raw||${CHK_WITH_DIGITS}|${CHK_VALID}|https://example.invalid/kind
"

run_case "AWS-account-ID-shaped digit run inside installed_sha256 (field 8)" accept \
  "scripts/lab/tool-versions.txt" \
  "kind|v0.33.0|linux-amd64|kind|raw||${CHK_VALID}|${CHK_WITH_DIGITS}|https://example.invalid/kind
"

run_case "AWS-account-ID-shaped digit run inside both SHA256 fields" accept \
  "scripts/lab/tool-versions.txt" \
  "kind|v0.33.0|linux-amd64|kind|raw||${CHK_WITH_DIGITS}|${CHK_WITH_DIGITS}|https://example.invalid/kind
"

run_case "AWS-account-ID-shaped digit run in the url field, valid checksums" reject \
  "scripts/lab/tool-versions.txt" \
  "kind|v0.33.0|linux-amd64|kind|raw||${CHK_VALID}|${CHK_VALID}|https://example.invalid/${AWS12}/kind
"

run_case "AWS-account-ID-shaped digit run in the filename field, valid checksums" reject \
  "scripts/lab/tool-versions.txt" \
  "kind|v0.33.0|linux-amd64|kind-${AWS12}|raw||${CHK_VALID}|${CHK_VALID}|https://example.invalid/kind
"

run_case "AWS-account-ID-shaped digit run in the version field, valid checksums" reject \
  "scripts/lab/tool-versions.txt" \
  "kind|v${AWS12}|linux-amd64|kind|raw||${CHK_VALID}|${CHK_VALID}|https://example.invalid/kind
"

run_case "AWS-account-ID-shaped digit run in archive_member, immediately beside valid checksums" reject \
  "scripts/lab/tool-versions.txt" \
  "helm|v4.2.4|linux-amd64|helm|tar.gz|linux-amd64/helm-${AWS12}|${CHK_VALID}|${CHK_VALID}|https://example.invalid/helm.tar.gz
"

run_case "malformed row: a 12-digit, non-64-hex download_sha256 is not masked" reject \
  "scripts/lab/tool-versions.txt" \
  "kind|v0.33.0|linux-amd64|kind|raw||${AWS12}|${CHK_VALID}|https://example.invalid/kind
"

run_case "identical accept-worthy row content outside scripts/lab/tool-versions.txt" reject \
  "scripts/lab/other-tool-versions.txt" \
  "kind|v0.33.0|linux-amd64|kind|raw||${CHK_WITH_DIGITS}|${CHK_VALID}|https://example.invalid/kind
"

# --- terraform/.terraform.lock.hcl's narrow, block-structural
# exception (Phase 2.7.1 pre-merge hardening): masks a zh:/h1: line
# ONLY when it is both exactly one of the two fixed shapes AND
# structurally inside a `hashes = [ ... ]` array nested inside a
# `provider "..." { ... }` block - never a blanket per-line shape
# match, never any other file. A well-formed h1 token is 43
# base64-alphabet characters followed by exactly one "=" (the standard
# encoding of a 32-byte SHA256 digest) - digits are valid base64
# characters, so digitstr(43) below is both a syntactically valid h1
# payload and (being all-digit) trivially contains a 12+ digit run. ---

H1_WITH_DIGITS="$(digitstr 43)="
H1_VALID="$(hexstr 43)="

real_lockfile="$here/terraform/.terraform.lock.hcl"
if [ ! -f "$real_lockfile" ]; then
  echo "FAIL: real lock file not found at $real_lockfile - cannot run the real-lockfile acceptance case" >&2
  fail=$((fail + 1))
else
  d="$(new_case_dir)"
  mkdir -p "$d/terraform"
  cp "$real_lockfile" "$d/terraform/.terraform.lock.hcl"
  set +e
  out="$(cd "$d" && bash "$validator" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "PASS: the real, currently-generated terraform/.terraform.lock.hcl is accepted as-is"
    pass=$((pass + 1))
  else
    echo "FAIL: the real terraform/.terraform.lock.hcl was rejected"
    printf '%s\n' "$out"
    fail=$((fail + 1))
  fi
fi

run_case "valid zh: token with a 12+ digit run inside its SHA256, structurally inside hashes[], is accepted" accept \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_WITH_DIGITS}\",
  ]
}
"

run_case "valid h1: token with a 12+ digit run, structurally inside hashes[], is accepted" accept \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"h1:${H1_WITH_DIGITS}\",
  ]
}
"

run_case "the same 12+ digit run outside any lock file (bare text) is rejected" reject \
  "notes.md" "account-shaped number ${AWS12} in prose
"

run_case "a valid-shaped zh: line with a digit run in a DIFFERENT .terraform.lock.hcl path is rejected" reject \
  "modules/example/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_WITH_DIGITS}\",
  ]
}
"

# --- Phase 3.1: the lock-file exception generalizes from the single
# original terraform/.terraform.lock.hcl to any Terraform root module's
# own lock file (terraform/bootstrap/, terraform/envs/*/, etc.) - each
# discovered independently by scripts/lab/terraform-root-modules.sh.
# The path must still genuinely start with "terraform/" and end in
# ".terraform.lock.hcl" - a lookalike path outside that prefix is not
# eligible, even though it contains the same substring. -----------------

run_case "a valid zh: token with a digit run, structurally inside hashes[], is accepted in terraform/bootstrap/.terraform.lock.hcl (one level deep)" accept \
  "terraform/bootstrap/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_WITH_DIGITS}\",
  ]
}
"

run_case "a valid zh: token with a digit run, structurally inside hashes[], is accepted in terraform/envs/network/.terraform.lock.hcl (two levels deep)" accept \
  "terraform/envs/network/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_WITH_DIGITS}\",
  ]
}
"

run_case "a lookalike path that merely contains \"terraform/\" as a substring, not a genuine prefix, is rejected" reject \
  "not-terraform/bootstrap/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_WITH_DIGITS}\",
  ]
}
"

run_case "a digit run inside a lock-file comment (not a hashes[] entry) is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "# account ${AWS12}
provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_VALID}\",
  ]
}
"

run_case "a digit run inside the version field (not a hashes[] entry) is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"${AWS12}\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_VALID}\",
  ]
}
"

run_case "a digit run inside the constraints field (not a hashes[] entry) is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"${AWS12}\"
  hashes = [
    \"zh:${CHK_VALID}\",
  ]
}
"

run_case "a digit run inside the provider address line (not a hashes[] entry) is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws-${AWS12}\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_VALID}\",
  ]
}
"

run_case "a zh: token one character short of 64 hex, with a digit run, is rejected (not masked)" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:$(printf '%s' "$CHK_WITH_DIGITS" | cut -c1-63)\",
  ]
}
"

run_case "a zh: token one character too long, with a digit run, is rejected (not masked)" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_WITH_DIGITS}0\",
  ]
}
"

run_case "a zh: token containing a non-hex character, with a digit run, is rejected (not masked)" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:$(printf '%s' "$CHK_WITH_DIGITS" | cut -c1-63)g\",
  ]
}
"

run_case "an otherwise-valid zh: line followed by a trailing comment containing a digit run is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_VALID}\", # account ${AWS12}
  ]
}
"

run_case "a digit run on the same line as an otherwise-valid zh: token, appended after the comma, is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_VALID}\", ${AWS12}
  ]
}
"

run_case "a well-shaped zh: line with a digit run OUTSIDE any hashes[] array (block never opened) is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "    \"zh:${CHK_WITH_DIGITS}\",
"

run_case "a well-shaped zh: line with a digit run inside a provider block whose hashes[] never opens is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
    \"zh:${CHK_WITH_DIGITS}\",
}
"

run_case "a well-shaped zh: line with a digit run appearing after hashes[] has already closed is rejected" reject \
  "terraform/.terraform.lock.hcl" \
  "provider \"registry.terraform.io/hashicorp/aws\" {
  version     = \"6.63.0\"
  constraints = \"6.63.0\"
  hashes = [
    \"zh:${CHK_VALID}\",
  ]
    \"zh:${CHK_WITH_DIGITS}\",
}
"

echo ""
echo "test-forbidden-terms: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "test-forbidden-terms: FAILED"
  exit 1
fi
echo "test-forbidden-terms: OK"
