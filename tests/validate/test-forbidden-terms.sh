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

echo ""
echo "test-forbidden-terms: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "test-forbidden-terms: FAILED"
  exit 1
fi
echo "test-forbidden-terms: OK"
