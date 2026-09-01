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

generic_patterns=(
  '[0-9]{12}'      # AWS-account-ID-shaped number
  '[0-9a-f]{40}'   # full git commit SHA-shaped token
)

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  checked=$((checked + 1))
  for p in "${generic_patterns[@]}"; do
    if grep -EIqn "$p" "$f" 2>/dev/null; then
      echo "FAIL: $f matches a restricted pattern class ($p) - confirm this is not a private identifier before committing"
      fail=1
    fi
  done
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
