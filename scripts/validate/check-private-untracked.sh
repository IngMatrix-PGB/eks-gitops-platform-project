#!/usr/bin/env bash
# Verifies that every local-only exclude rule in .git/info/exclude is
# actually honored: nothing it covers is tracked by Git, the path it
# covers (if present locally) is genuinely git-ignored, and no versioned
# ignore file (.gitignore) duplicates a local-only rule.
#
# This script never hardcodes the name of any local-only path, and on
# FAILURE it never prints:
#   - the raw pattern read from .git/info/exclude,
#   - the cleaned/resolved path derived from it, or
#   - any file name found to be tracked.
# Only a generic message and a count are ever printed. This is
# deliberate: even a validation failure message must not leak the name
# or location of confidentiality-sensitive local material.
set -uo pipefail

exclude_file=".git/info/exclude"
fail=0
violation_count=0
pattern_count=0

if [ ! -f "$exclude_file" ]; then
  echo "check-private-untracked: OK (no local exclude file present)"
  exit 0
fi

patterns=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$exclude_file" || true)

if [ -z "$patterns" ]; then
  echo "check-private-untracked: OK (no local-only exclude patterns configured)"
  exit 0
fi

while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  pattern_count=$((pattern_count + 1))

  cleaned="${pattern#/}"
  cleaned="${cleaned%/}"
  [ -z "$cleaned" ] && continue

  tracked=$(git ls-files -- "$cleaned" 2>/dev/null || true)
  if [ -n "$tracked" ]; then
    violation_count=$((violation_count + 1))
    fail=1
  fi

  if [ -e "$cleaned" ]; then
    if ! git check-ignore -q -- "$cleaned"; then
      violation_count=$((violation_count + 1))
      fail=1
    fi
  fi

  if [ -f .gitignore ] && grep -qF "$cleaned" .gitignore 2>/dev/null; then
    violation_count=$((violation_count + 1))
    fail=1
  fi
done <<< "$patterns"

if [ "$fail" -ne 0 ]; then
  echo "FAIL: a local-only excluded path is tracked or not correctly ignored ($violation_count issue(s) across $pattern_count local-only pattern(s))"
  echo "check-private-untracked: FAILED"
  exit 1
fi
echo "check-private-untracked: OK ($pattern_count local-only pattern(s) verified)"
