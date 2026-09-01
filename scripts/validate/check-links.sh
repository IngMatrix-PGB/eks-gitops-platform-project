#!/usr/bin/env bash
# Verifies every local (non-http, non-anchor-only) Markdown link in a
# versionable .md file resolves to a file that actually exists.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$here/_lib.sh"

fail=0
checked=0

while IFS= read -r f; do
  [ -z "$f" ] && continue
  dir=$(dirname "$f")

  links=$(grep -oE '\]\([^)[:space:]]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//')
  [ -z "$links" ] && continue

  while IFS= read -r link; do
    [ -z "$link" ] && continue
    case "$link" in
      http://*|https://*|mailto:*|\#*) continue ;;
    esac
    target="${link%%#*}"
    [ -z "$target" ] && continue
    checked=$((checked + 1))
    resolved="$dir/$target"
    if [ ! -e "$resolved" ]; then
      echo "FAIL: $f -> broken local link '$link'"
      fail=1
    fi
  done <<< "$links"
done < <(list_versionable_markdown)

if [ "$fail" -ne 0 ]; then
  echo "check-links: FAILED"
  exit 1
fi
echo "check-links: OK ($checked local links checked)"
