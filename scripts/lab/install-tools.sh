#!/bin/sh
# Downloads and verifies the pinned project-local lab toolchain into
# .tools/bin/. Supports both raw-binary downloads (kind, kubectl) and
# tar.gz archives (helm), with archive extraction restricted to exactly
# one validated, regular-file member. Never installs globally, never
# uses Homebrew, never uses sudo, never modifies $PATH. Backs
# `make tools-install` only.
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

while IFS='|' read -r name version platform filename archive_type archive_member download_sha installed_sha url; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac

  dest=".tools/bin/${filename}"
  tmp_dest="${tmpdir}/${filename}.download"

  echo "tools-install: downloading $name $version from $url ..."
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
      echo "OK: $name $version installed at $dest (checksum verified)"
      ;;
    tar.gz)
      if extract_pinned_member "$tmp_dest" "$archive_member" "$installed_sha" "$dest"; then
        echo "OK: $name $version installed at $dest (archive checksum + extracted binary checksum verified)"
      else
        echo "FAIL: archive installation failed for $name" >&2
        fail=1
      fi
      ;;
    *)
      echo "FAIL: unknown archive_type '$archive_type' for $name" >&2
      fail=1
      ;;
  esac
done < "$versions_file"

if [ "$fail" -ne 0 ]; then
  echo "tools-install: FAILED"
  exit 1
fi
echo "tools-install: OK"
