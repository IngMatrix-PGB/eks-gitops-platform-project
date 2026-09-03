#!/bin/sh
# Downloads and verifies the pinned project-local lab toolchain into
# .tools/bin/. Supports both raw-binary downloads (kind, kubectl) and
# tar.gz archives (helm), with archive extraction restricted to exactly
# one validated, regular-file member. Never installs globally, never
# uses Homebrew, never uses sudo, never modifies $PATH. Backs
# `make tools-install` only.
#
# Supports exactly two platforms - darwin-arm64 and linux-amd64 -
# detected via `uname`, matched against scripts/lab/tool-versions.txt's
# own `platform` column. Idempotent: a destination binary that already
# matches its pinned checksum and executes successfully is left alone,
# never re-downloaded.
set -eu

# --- pure, offline platform-normalization logic -----------------------
# Deliberately separated from every filesystem/network side effect below
# so tests/lab/test-tool-platforms.sh can source this file with
# INSTALL_TOOLS_SOURCE_ONLY=1 and exercise normalize_platform()/
# detect_platform() directly, against synthetic uname(1) output, with no
# repository, cluster, or network dependency at all.

# $1=uname -s output, $2=uname -m output. On stdout: the normalized
# "<os>-<arch>" string for exactly the two supported platform pairs.
# Fails closed (nothing printed, non-zero return) for anything else -
# no aliasing across the two supported pairs, no fallback.
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

# Sets PLATFORM from the real `uname`, or fails closed with a clear,
# named error - never silently falls back to a different platform's
# pinned tools.
detect_platform() {
  raw_os="$(uname -s)"
  raw_arch="$(uname -m)"
  if ! PLATFORM="$(normalize_platform "$raw_os" "$raw_arch")"; then
    echo "FAIL: unsupported platform '$raw_os/$raw_arch' - only Darwin/arm64 (darwin-arm64) and Linux/amd64 (linux-amd64) are supported; no fallback" >&2
    return 1
  fi
}

# Test-only early exit: everything below this point touches the real
# repository, filesystem, and network, and must never run just because
# this file was sourced for unit testing.
if [ "${INSTALL_TOOLS_SOURCE_ONLY:-0}" = "1" ]; then
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
echo "tools-install: detected platform $PLATFORM"

# Confirms an installed binary actually runs, not just that its bytes
# match a checksum - a wrong-platform binary (e.g. a darwin binary
# copied onto a linux host) passes a checksum check but fails here with
# "Exec format error", which is exactly the failure this whole platform
# match/idempotency design exists to prevent.
verify_executable() {
  name="$1"; dest="$2"
  case "$name" in
    kind) "$dest" version >/dev/null 2>&1 ;;
    kubectl) "$dest" version --client >/dev/null 2>&1 ;;
    helm) "$dest" version >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

versions_file="scripts/lab/tool-versions.txt"
if [ ! -f "$versions_file" ]; then
  echo "FAIL: $versions_file not found" >&2
  exit 1
fi

mkdir -p .tools/bin

# Temp dir created under .tools/ (same filesystem as the destination) so
# every final `mv` below is an atomic rename, not a cross-device copy.
tmpdir="$(mktemp -d ".tools/tmp.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

fail=0

# Extracts exactly one validated, regular-file archive member and
# atomically installs it. Never extracts the whole archive blindly.
#   $1 archive path   $2 member path inside the archive
#   $3 expected installed_sha256   $4 final destination
extract_pinned_member() {
  archive="$1"; member="$2"; installed_sha="$3"; dest="$4"

  # 1. Validate the configured member string: no absolute path, no ".."
  #    traversal, never empty.
  case "$member" in
    /*|*..*|"")
      echo "FAIL: unsafe or empty archive member '$member'" >&2
      return 1
      ;;
  esac

  # 2. Inspect the archive entry type before extracting anything. The
  #    first character of tar's verbose-listing mode string identifies
  #    the entry type: '-' regular file, 'l' symlink, 'd' directory, etc.
  entry_line="$(tar tvzf "$archive" "$member" 2>/dev/null || true)"
  if [ -z "$entry_line" ]; then
    echo "FAIL: archive member '$member' not found in $archive" >&2
    return 1
  fi
  entry_count="$(printf '%s\n' "$entry_line" | wc -l | tr -d ' ')"
  entry_type="$(printf '%s' "$entry_line" | cut -c1)"

  # 3 & 4. Require exactly one regular-file entry; reject symlinks and
  # any other special entry.
  if [ "$entry_count" != "1" ]; then
    echo "FAIL: archive member '$member' matched $entry_count entries, expected exactly 1" >&2
    return 1
  fi
  if [ "$entry_type" != "-" ]; then
    echo "FAIL: archive member '$member' is not a regular file (type '$entry_type')" >&2
    return 1
  fi
  case "$entry_line" in
    *" -> "*)
      echo "FAIL: archive member '$member' is a symlink" >&2
      return 1
      ;;
  esac

  # 5. Extract only that exact member.
  extract_root="${tmpdir}/extract-$$"
  mkdir -p "$extract_root"
  if ! tar xzf "$archive" -C "$extract_root" "$member"; then
    echo "FAIL: extraction of '$member' failed" >&2
    return 1
  fi
  extracted="${extract_root}/${member}"

  # 6. Confirm the extracted path remains inside the temporary
  # directory (no realpath/readlink -f dependency - cd+pwd -P is
  # POSIX-guaranteed on macOS).
  extract_root_real="$(cd "$extract_root" && pwd -P)"
  extracted_dir_real="$(cd "$(dirname "$extracted")" && pwd -P)"
  case "$extracted_dir_real" in
    "$extract_root_real"|"$extract_root_real"/*) : ;;
    *)
      echo "FAIL: extracted path escaped the temporary directory" >&2
      return 1
      ;;
  esac
  if [ ! -f "$extracted" ]; then
    echo "FAIL: extracted member is not a regular file on disk" >&2
    return 1
  fi

  # 7. Verify the extracted binary checksum.
  actual_sha="$(shasum -a 256 "$extracted" | awk '{print $1}')"
  if [ "$actual_sha" != "$installed_sha" ]; then
    echo "FAIL: extracted binary checksum mismatch for $dest - expected $installed_sha, got $actual_sha" >&2
    return 1
  fi

  # 8. Atomically move only the verified binary.
  chmod +x "$extracted"
  mv "$extracted" "$dest"
  return 0
}

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

  # Idempotency: a destination that already carries the pinned checksum
  # and actually runs needs no work. A checksum match with a broken
  # executable (e.g. truncated by an interrupted previous run) is not
  # trusted - it falls through and is reinstalled from scratch.
  if [ -x "$dest" ]; then
    existing_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [ "$existing_sha" = "$installed_sha" ] && verify_executable "$name" "$dest"; then
      echo "OK: $name $version already installed at $dest for $PLATFORM (idempotent - checksum verified, executes successfully)"
      continue
    fi
  fi

  tmp_dest="${tmpdir}/${filename}.download"

  echo "tools-install: downloading $name $version ($PLATFORM) from $url ..."
  if ! curl -fsSL -o "$tmp_dest" "$url"; then
    echo "FAIL: download failed for $name from $url" >&2
    fail=1
    continue
  fi

  actual_download_sha="$(shasum -a 256 "$tmp_dest" | awk '{print $1}')"
  if [ "$actual_download_sha" != "$download_sha" ]; then
    echo "FAIL: checksum mismatch for downloaded $name - expected $download_sha, got $actual_download_sha" >&2
    echo "      leaving no executable at $dest" >&2
    fail=1
    continue
  fi

  case "$archive_type" in
    raw)
      chmod +x "$tmp_dest"
      mv "$tmp_dest" "$dest"
      ;;
    tar.gz)
      if ! extract_pinned_member "$tmp_dest" "$archive_member" "$installed_sha" "$dest"; then
        echo "FAIL: archive installation failed for $name" >&2
        fail=1
        continue
      fi
      ;;
    *)
      echo "FAIL: unknown archive_type '$archive_type' for $name" >&2
      fail=1
      continue
      ;;
  esac

  if ! verify_executable "$name" "$dest"; then
    echo "FAIL: $name $version installed at $dest but failed to execute successfully (wrong-platform or corrupt binary)" >&2
    fail=1
    continue
  fi
  echo "OK: $name $version installed at $dest for $PLATFORM (checksum verified, executes successfully)"
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
  echo "tools-install: FAILED"
  exit 1
fi
echo "tools-install: OK"
