#!/bin/sh
# Read-only prerequisite check for the local lab toolchain. Never
# downloads or installs anything - backs `make tools-check` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=_lib.sh
. scripts/lab/_lib.sh
require_repo_root

fail=0

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL: docker not found in PATH" >&2
  fail=1
elif ! docker info >/dev/null 2>&1; then
  echo "FAIL: docker daemon not reachable" >&2
  fail=1
else
  echo "OK: docker daemon reachable"
fi

versions_file="scripts/lab/tool-versions.txt"
if [ ! -f "$versions_file" ]; then
  echo "FAIL: $versions_file not found" >&2
  exit 1
fi

while IFS='|' read -r name version platform filename archive_type archive_member download_sha installed_sha url; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  dest=".tools/bin/${filename}"
  if [ ! -x "$dest" ]; then
    echo "FAIL: $name $version not installed at $dest - run 'make tools-install'" >&2
    fail=1
    continue
  fi
  # Always compare against installed_sha256 - the checksum of the file
  # actually placed at .tools/bin/<filename>, never download_sha256 (for
  # archive-sourced tools those are two different files' hashes; for raw
  # downloads the two columns are identical anyway).
  actual_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [ "$actual_sha" != "$installed_sha" ]; then
    echo "FAIL: $name at $dest does not match the pinned installed checksum for $version" >&2
    fail=1
    continue
  fi
  echo "OK: $name $version at $dest (checksum verified)"
done < "$versions_file"

if [ "$fail" -ne 0 ]; then
  echo "tools-check: FAILED"
  exit 1
fi
echo "tools-check: OK"
