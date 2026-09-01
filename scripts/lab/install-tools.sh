#!/bin/sh
# Downloads and verifies the pinned project-local lab toolchain into
# .tools/bin/. Never installs globally, never uses Homebrew, never uses
# sudo, never modifies $PATH. Backs `make tools-install` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=_lib.sh
. scripts/lab/_lib.sh
require_repo_root

versions_file="scripts/lab/tool-versions.txt"
if [ ! -f "$versions_file" ]; then
  echo "FAIL: $versions_file not found" >&2
  exit 1
fi

mkdir -p .tools/bin

# Temp dir created under .tools/ (same filesystem as the destination) so
# the final `mv` below is an atomic rename, not a cross-device copy.
tmpdir="$(mktemp -d ".tools/tmp.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

fail=0

while IFS='|' read -r name version platform filename sha256 url; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac

  dest=".tools/bin/${filename}"
  tmp_dest="${tmpdir}/${filename}"

  echo "tools-install: downloading $name $version from $url ..."
  if ! curl -fsSL -o "$tmp_dest" "$url"; then
    echo "FAIL: download failed for $name from $url" >&2
    fail=1
    continue
  fi

  actual_sha="$(shasum -a 256 "$tmp_dest" | awk '{print $1}')"
  if [ "$actual_sha" != "$sha256" ]; then
    echo "FAIL: checksum mismatch for $name - expected $sha256, got $actual_sha" >&2
    echo "      leaving no executable at $dest" >&2
    fail=1
    continue
  fi

  chmod +x "$tmp_dest"
  mv "$tmp_dest" "$dest"
  echo "OK: $name $version installed at $dest (checksum verified)"
done < "$versions_file"

if [ "$fail" -ne 0 ]; then
  echo "tools-install: FAILED"
  exit 1
fi
echo "tools-install: OK"
