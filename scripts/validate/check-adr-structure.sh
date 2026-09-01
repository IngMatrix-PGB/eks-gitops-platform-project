#!/usr/bin/env bash
# Verifies every ADR under docs/adr/ follows the required structure:
#   - exactly one recognized status (Proposed, Accepted, Deprecated,
#     Superseded) - Accepted is a legitimate status once an ADR has been
#     formally reviewed, so this check never treats it as a failure by
#     itself; it only fails on a missing, unrecognized, or duplicated
#     status line.
#   - every required section present as an exact, line-anchored H2
#     heading (not a word found inside a paragraph)
#   - no required section heading duplicated
#
# Limitation: this is a structural check, not a content review. It does
# not verify that a section's prose actually says anything meaningful -
# only that the required headings exist, are well-formed, and are not
# duplicated.
set -uo pipefail

adr_dir="docs/adr"
fail=0
count=0

allowed_statuses=("Proposed" "Accepted" "Deprecated" "Superseded")

required_headers=(
  "## Context"
  "## Decision"
  "## Alternatives Considered"
  "## Consequences"
  "## Security and Cost Implications"
  "## Validation Method"
)

if [ ! -d "$adr_dir" ]; then
  echo "FAIL: $adr_dir does not exist"
  exit 1
fi

is_allowed_status() {
  local value="$1"
  local s
  for s in "${allowed_statuses[@]}"; do
    [ "$value" = "$s" ] && return 0
  done
  return 1
}

for f in "$adr_dir"/*.md; do
  [ -e "$f" ] || continue
  count=$((count + 1))

  status_lines=$(grep -cE '^\*\*Status:\*\* ' "$f")
  if [ "$status_lines" -eq 0 ]; then
    echo "FAIL: $f is missing a '**Status:** ...' line"
    fail=1
  elif [ "$status_lines" -gt 1 ]; then
    echo "FAIL: $f has more than one '**Status:** ...' line"
    fail=1
  else
    status_value=$(grep -E '^\*\*Status:\*\* ' "$f" | head -n1 | sed -E 's/^\*\*Status:\*\* //; s/[[:space:]]*$//')
    if ! is_allowed_status "$status_value"; then
      echo "FAIL: $f has an unrecognized status (must be exactly one of: Proposed, Accepted, Deprecated, Superseded)"
      fail=1
    fi
  fi

  for h in "${required_headers[@]}"; do
    # Exact, line-anchored match: the whole line must equal the heading,
    # not merely contain it as a substring inside a paragraph.
    occurrences=$(grep -cxF "$h" "$f")
    if [ "$occurrences" -eq 0 ]; then
      echo "FAIL: $f is missing required section '$h' as an exact heading line"
      fail=1
    elif [ "$occurrences" -gt 1 ]; then
      echo "FAIL: $f has required section '$h' duplicated ($occurrences occurrences)"
      fail=1
    fi
  done
done

if [ "$count" -eq 0 ]; then
  echo "FAIL: no ADR files found in $adr_dir"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-adr-structure: FAILED"
  exit 1
fi
echo "check-adr-structure: OK ($count ADRs checked)"
