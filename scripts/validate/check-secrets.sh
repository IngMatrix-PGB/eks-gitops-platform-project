#!/usr/bin/env bash
# Generic secret-shaped pattern scan over every versionable file.
# Pattern-based, not exhaustive - see the risk table in
# docs/architecture/technical-architecture.md.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$here/_lib.sh"

fail=0
checked=0

patterns=(
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  'aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+=]{30,}'
  'xox[baprs]-[0-9A-Za-z-]{10,}'
  'ghp_[A-Za-z0-9]{30,}'
)

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  checked=$((checked + 1))
  for p in "${patterns[@]}"; do
    if grep -EIqn "$p" "$f" 2>/dev/null; then
      echo "FAIL: $f matches a secret-shaped pattern"
      fail=1
    fi
  done
done < <(list_versionable_files)

if [ "$checked" -eq 0 ]; then
  echo "FAIL: no versionable files found to scan"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-secrets: FAILED"
  exit 1
fi
echo "check-secrets: OK ($checked files scanned)"
