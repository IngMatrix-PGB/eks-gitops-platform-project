#!/usr/bin/env bash
# Basic Markdown formatting checks over every versionable .md file:
#   - not empty
#   - exactly one H1 heading ("# ...", line-anchored), and it is the
#     first non-empty line
#   - no literal tab characters
#   - no unintentional trailing whitespace - a literal two-space Markdown
#     hard line break is the only trailing whitespace allowed
#   - ends with a trailing newline
#
# Limitation: this is a lightweight, project-specific formatting check,
# not a general-purpose Markdown linter. It does not validate link
# syntax, list formatting, table alignment, or prose quality.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$here/_lib.sh"

fail=0
count=0

while IFS= read -r f; do
  [ -z "$f" ] && continue
  count=$((count + 1))

  if [ ! -s "$f" ]; then
    echo "FAIL: $f is empty"
    fail=1
    continue
  fi

  h1_count=$(grep -cE '^# [^#]' "$f")
  if [ "$h1_count" -eq 0 ]; then
    echo "FAIL: $f has no top-level H1 heading ('# ...')"
    fail=1
  elif [ "$h1_count" -gt 1 ]; then
    echo "FAIL: $f has more than one top-level H1 heading ($h1_count found)"
    fail=1
  fi

  first_line=$(head -n 1 "$f")
  if [[ "$first_line" != "# "* ]]; then
    echo "FAIL: $f does not start with its H1 heading on the first line"
    fail=1
  fi

  if grep -q "$(printf '\t')" "$f"; then
    echo "FAIL: $f contains literal tab characters"
    fail=1
  fi

  # Trailing whitespace: allow exactly two trailing spaces (an
  # intentional Markdown hard break); reject one space, three or more
  # spaces, or a trailing tab.
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ [[:space:]]+$ ]]; then
      trailing="${BASH_REMATCH[0]}"
      if [ "$trailing" != "  " ]; then
        echo "FAIL: $f has a line with unintentional trailing whitespace (only a literal two-space hard break is allowed)"
        fail=1
        break
      fi
    fi
  done < "$f"

  last_byte=$(tail -c 1 "$f" | od -An -tx1 | tr -d ' \n')
  if [ "$last_byte" != "0a" ]; then
    echo "FAIL: $f does not end with a trailing newline"
    fail=1
  fi
done < <(list_versionable_markdown)

if [ "$count" -eq 0 ]; then
  echo "FAIL: no versionable Markdown files found"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-markdown-basic: FAILED"
  exit 1
fi
echo "check-markdown-basic: OK ($count files checked)"
