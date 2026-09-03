#!/bin/sh
# Read-only prerequisite check for the local lab toolchain. Never
# downloads or installs anything - backs `make tools-check` only.
#
# Supports exactly two platforms - darwin-arm64 and linux-amd64 -
# detected via `uname`, matched against scripts/lab/tool-versions.txt's
# own `platform` column so only the row(s) pinned for this machine are
# checked against .tools/bin/<filename>.
set -eu

# --- pure, offline platform-normalization logic -----------------------
# Kept identical to scripts/lab/install-tools.sh's own copy (duplicated,
# not shared, since neither script sources the other); both copies are
# exercised by tests/lab/test-tool-platforms.sh to catch any drift
# between them. See that script for why this is a separate function
# rather than inlined, and why sourcing with
# CHECK_PREREQUISITES_SOURCE_ONLY=1 skips everything below it.
normalize_platform() {
  raw_os="$1"; raw_arch="$2"
  case "$raw_os" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) return 1 ;;
  esac
  case "$raw_arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="amd64" ;;
    *) return 1 ;;
  esac
  case "${os}-${arch}" in
    darwin-arm64|linux-amd64) printf '%s' "${os}-${arch}"; return 0 ;;
    *) return 1 ;;
  esac
}

detect_platform() {
  raw_os="$(uname -s)"
  raw_arch="$(uname -m)"
  if ! PLATFORM="$(normalize_platform "$raw_os" "$raw_arch")"; then
    echo "FAIL: unsupported platform '$raw_os/$raw_arch' - only Darwin/arm64 (darwin-arm64) and Linux/amd64 (linux-amd64) are supported; no fallback" >&2
    return 1
  fi
}

if [ "${CHECK_PREREQUISITES_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=_lib.sh
. scripts/lab/_lib.sh
require_repo_root

if ! detect_platform; then
  exit 1
fi
echo "tools-check: detected platform $PLATFORM"

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

all_names=""
matched_names=""
while IFS='|' read -r name version platform filename archive_type archive_member download_sha installed_sha url; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  case " $all_names " in
    *" $name "*) : ;;
    *) all_names="$all_names $name" ;;
  esac
  [ "$platform" = "$PLATFORM" ] || continue
  case " $matched_names " in
    *" $name "*) : ;;
    *) matched_names="$matched_names $name" ;;
  esac
  dest=".tools/bin/${filename}"
  if [ ! -x "$dest" ]; then
    echo "FAIL: $name $version not installed at $dest for $PLATFORM - run 'make tools-install'" >&2
    fail=1
    continue
  fi
  # Always compare against installed_sha256 - the checksum of the file
  # actually placed at .tools/bin/<filename>, never download_sha256 (for
  # archive-sourced tools those are two different files' hashes; for raw
  # downloads the two columns are identical anyway).
  actual_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [ "$actual_sha" != "$installed_sha" ]; then
    echo "FAIL: $name at $dest does not match the pinned installed checksum for $version ($PLATFORM)" >&2
    fail=1
    continue
  fi
  echo "OK: $name $version at $dest for $PLATFORM (checksum verified)"
done < "$versions_file"

if [ -z "$all_names" ]; then
  echo "FAIL: $versions_file has no tool entries at all" >&2
  fail=1
else
  for name in $all_names; do
    case " $matched_names " in
      *" $name "*) : ;;
      *)
        echo "FAIL: $name has no $versions_file entry for detected platform $PLATFORM - fail-closed, not silently skipped" >&2
        fail=1
        ;;
    esac
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "tools-check: FAILED"
  exit 1
fi
echo "tools-check: OK"
