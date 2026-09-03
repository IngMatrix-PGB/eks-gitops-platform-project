#!/usr/bin/env bash
# Scans every versionable file for confidentiality-restricted content:
#
#  1. Generic pattern classes that always run, in every clone, with no
#     extra setup: AWS-account-ID-shaped numbers and full-git-commit-SHA-
#     shaped hex strings. These patterns are deliberately generic - they
#     never encode any specific private identifier.
#
#  2. An OPTIONAL local-only exact-term denylist read from
#     scripts/validate/local-denylist.txt, one term per line. That file
#     is intentionally never versioned (it is excluded the same way any
#     other local-only material is - via .git/info/exclude, never a
#     committed ignore file), so a fresh clone runs the generic checks
#     above with no missing dependency. Its purpose is to let a
#     contributor who has any local, non-shared confidentiality context
#     get real enforcement locally, without that context - or even the
#     fact that it exists - ever being committed.
#
# Limitation: both the generic patterns and the local denylist are
# pattern/exact-string matches - this is not a general-purpose secret or
# PII scanner, and coverage is limited to what is explicitly listed here.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$here/_lib.sh"

fail=0
checked=0

aws_account_pattern='[0-9]{12}'      # AWS-account-ID-shaped number

# Narrow, single-purpose exception: scripts/lab/tool-versions.txt's own
# documented 9-field pipe format
# (name|version|platform|filename|archive_type|archive_member|
# download_sha256|installed_sha256|url) pins real, externally-fixed
# SHA256 checksums verified against each tool's official upstream
# release - a 64-hex-character digest can coincidentally contain a run
# of 12+ consecutive digits (true of at least one of kind's published
# checksums) with no way to change even one character without breaking
# the checksum it exists to verify. This masks ONLY fields 7 and 8
# (download_sha256, installed_sha256), and ONLY when each is exactly a
# well-formed 64-hex-character value, before running
# $aws_account_pattern against what remains of the line - never the
# whole line, never any other field, never a malformed checksum, never
# any file other than this exact path.
tool_versions_row_pattern='^([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([0-9A-Fa-f]{64})\|([0-9A-Fa-f]{64})\|([^|]*)$'

aws_account_hit_in_file() {
  local file="$1"
  if [ "$file" = "scripts/lab/tool-versions.txt" ]; then
    local line masked
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ $tool_versions_row_pattern ]]; then
        masked="${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${BASH_REMATCH[3]}|${BASH_REMATCH[4]}|${BASH_REMATCH[5]}|${BASH_REMATCH[6]}|SHA256-FIELD|SHA256-FIELD|${BASH_REMATCH[9]}"
      else
        masked="$line"
      fi
      if [[ "$masked" =~ $aws_account_pattern ]]; then
        return 0
      fi
    done < "$file"
    return 1
  fi
  grep -EIqn "$aws_account_pattern" "$file" 2>/dev/null
}
# Exact-length match with explicit non-hex boundaries, not \b: a
# 40-hex-char SHA-1-shaped token must never match as a substring of a
# legitimate longer digest (e.g. a 64-char SHA256), and \b is
# unreliable here because word-boundary semantics also react to
# underscores and other non-hex word characters around a hex run.
sha1_pattern='(^|[^0-9A-Fa-f])[0-9A-Fa-f]{40}([^0-9A-Fa-f]|$)'   # exact 40-hex SHA-1-shaped token, case-insensitive-safe

# Narrow, single-purpose exception: GitHub Actions immutable action pins
# are themselves 40-hex commit SHAs (e.g. `uses: actions/checkout@<sha>`),
# which would otherwise always trip $sha1_pattern in every workflow file.
# Rather than exclude .github/ from scanning (which would blind the
# scanner to any other restricted content placed there), this accepts
# exactly one, fully-anchored line shape and nothing else: the complete,
# trimmed line must be only "- uses: actions/checkout@<40-hex>" (an
# optional leading list-item dash, the literal key "uses:", and the
# literal repository "actions/checkout" - no other action/repository, no
# inline comment, no trailing version annotation, no other text on the
# line). It is also scoped to files literally under .github/workflows/
# with a .yml/.yaml extension, so it can never apply anywhere else in the
# repository.
is_allowed_checkout_pin() {
  local file="$1" line="$2"
  case "$file" in
    .github/workflows/*.yml|.github/workflows/*.yaml) : ;;
    *) return 1 ;;
  esac
  [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*actions/checkout@[0-9A-Fa-f]{40}[[:space:]]*$ ]]
}

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  checked=$((checked + 1))

  if aws_account_hit_in_file "$f"; then
    echo "FAIL: $f matches a restricted pattern class ($aws_account_pattern) - confirm this is not a private identifier before committing"
    fail=1
  fi

  while IFS=: read -r lineno line; do
    [ -z "$lineno" ] && continue
    if is_allowed_checkout_pin "$f" "$line"; then
      continue
    fi
    echo "FAIL: $f:$lineno matches a restricted pattern class ($sha1_pattern) - confirm this is not a private identifier before committing"
    fail=1
  done < <(grep -EIn "$sha1_pattern" "$f" 2>/dev/null)
done < <(list_versionable_files)

local_denylist="$here/local-denylist.txt"
if [ -f "$local_denylist" ]; then
  while IFS= read -r term; do
    [ -z "$term" ] && continue
    [[ "$term" == \#* ]] && continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -f "$f" ] || continue
      if grep -Iqn -F -- "$term" "$f" 2>/dev/null; then
        echo "FAIL: $f contains a term from the local confidentiality denylist"
        fail=1
      fi
    done < <(list_versionable_files)
  done < "$local_denylist"
else
  echo "NOTE: no local confidentiality denylist at $local_denylist - running generic checks only"
fi

if [ "$checked" -eq 0 ]; then
  echo "FAIL: no versionable files found to scan"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-forbidden-terms: FAILED"
  exit 1
fi
echo "check-forbidden-terms: OK ($checked files scanned)"
