#!/bin/sh
# Offline regression matrix for the two-platform (darwin-arm64,
# linux-amd64) support in scripts/lab/install-tools.sh and
# scripts/lab/check-prerequisites.sh. Never touches the network, never
# touches this repository's own .tools/ or .local/kubeconfig, never
# requires a real cluster. Backs `make check-tool-platforms-regression`
# only.
#
# Two layers:
#   A. Pure unit matrix over normalize_platform(), sourced out of both
#      real scripts (INSTALL_TOOLS_SOURCE_ONLY=1 /
#      CHECK_PREREQUISITES_SOURCE_ONLY=1) with synthetic uname(1)
#      output - no filesystem/network dependency at all.
#   B. Integration matrix that runs the real scripts, unmodified,
#      against a synthetic fixture repository (its own .git/,
#      scripts/lab/_lib.sh copied verbatim, a throwaway
#      tool-versions.txt, and a throwaway .tools/bin/), with `uname`
#      and `curl` replaced by tiny fixture-driven fakes placed first on
#      PATH. This proves the real row-selection, checksum,
#      idempotency, execution-verification, and fail-closed logic, not
#      a re-implementation of it.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
if [ ! -f "$here/scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi

install_tools_src="$here/scripts/lab/install-tools.sh"
check_prereq_src="$here/scripts/lab/check-prerequisites.sh"
lib_src="$here/scripts/lab/_lib.sh"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM

fail=0
pass=0

report() {
  # $1=0/1 (0 pass, 1 fail)  $2=description
  if [ "$1" -eq 0 ]; then
    echo "OK: $2"
    pass=$((pass + 1))
  else
    echo "FAIL: $2" >&2
    fail=$((fail + 1))
  fi
}

# ======================================================================
# A. Pure normalize_platform() matrix - no filesystem/network at all.
# ======================================================================

# Sources $1 (a script) with $2=env-var-name set to 1 first, so only its
# function definitions land in this shell - the script's own real work
# (repo checks, downloads, cluster access) is skipped by its own guard.
source_for_test() {
  script="$1"; guard_var="$2"
  eval "$guard_var=1"
  # shellcheck disable=SC1090
  . "$script"
  unset "$guard_var"
}

check_normalize_case() {
  # $1=label  $2=raw_os  $3=raw_arch  $4=expected ("" means "must fail")
  label="$1"; raw_os="$2"; raw_arch="$3"; expected="$4"
  got=""
  ok=0
  if got="$(normalize_platform "$raw_os" "$raw_arch")"; then
    rc=0
  else
    rc=1
  fi
  if [ -z "$expected" ]; then
    [ "$rc" -ne 0 ] || ok=1
  else
    [ "$rc" -eq 0 ] && [ "$got" = "$expected" ] || ok=1
  fi
  report "$ok" "normalize_platform ($label): $raw_os/$raw_arch -> ${expected:-<reject>}"
}

run_normalize_matrix() {
  caller_label="$1"
  check_normalize_case "$caller_label" "Darwin" "arm64" "darwin-arm64"
  check_normalize_case "$caller_label" "Linux" "amd64" "linux-amd64"
  check_normalize_case "$caller_label" "Linux" "x86_64" "linux-amd64"
  check_normalize_case "$caller_label" "Darwin" "x86_64" ""
  check_normalize_case "$caller_label" "Linux" "aarch64" ""
  check_normalize_case "$caller_label" "Linux" "arm64" ""
  check_normalize_case "$caller_label" "Windows_NT" "x86_64" ""
  check_normalize_case "$caller_label" "" "" ""
  check_normalize_case "$caller_label" "Darwin" "" ""
}

cd "$here"
source_for_test "$install_tools_src" INSTALL_TOOLS_SOURCE_ONLY
run_normalize_matrix "install-tools.sh"

source_for_test "$check_prereq_src" CHECK_PREREQUISITES_SOURCE_ONLY
run_normalize_matrix "check-prerequisites.sh"

# ======================================================================
# B. Integration matrix against a synthetic fixture repository.
# ======================================================================

fixture_repo="$root/fixture-repo"
fake_bin="$root/fake-bin"
curl_map="$root/curl-map"
curl_calls="$root/curl-calls"

setup_fixture_repo() {
  rm -rf "$fixture_repo"
  mkdir -p "$fixture_repo/.git" "$fixture_repo/scripts/lab" "$fixture_repo/.tools/bin"
  cp "$lib_src" "$fixture_repo/scripts/lab/_lib.sh"
  cp "$install_tools_src" "$fixture_repo/scripts/lab/install-tools.sh"
  cp "$check_prereq_src" "$fixture_repo/scripts/lab/check-prerequisites.sh"
}

setup_fakes() {
  mkdir -p "$fake_bin" "$curl_map"
  : > "$curl_calls"

  cat > "$fake_bin/uname" <<'EOS'
#!/bin/sh
case "$1" in
  -s) printf '%s\n' "$FAKE_UNAME_S" ;;
  -m) printf '%s\n' "$FAKE_UNAME_M" ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$fake_bin/uname"

  cat > "$fake_bin/curl" <<'EOS'
#!/bin/sh
# Fake curl: never touches the network. This project always invokes
# curl as exactly `curl -fsSL -o <dest> <url>` (4 arguments), so the
# destination and URL are read positionally rather than generically
# parsed. Looks up sha256(url) in $CURL_MAP_DIR (populated by the test
# harness before each case, via the real environment - not baked into
# this file's text) and copies that fixture to <dest>. Any URL not
# explicitly mapped is a hard failure, not a silent no-op - this is
# what catches a regression that fetches an unintended platform's row.
dest="$3"
url="$4"
echo "1" >> "$CURL_CALLS"
key="$(printf '%s' "$url" | shasum -a 256 | awk '{print $1}')"
src="$CURL_MAP_DIR/$key"
if [ ! -f "$src" ]; then
  echo "fake curl: no fixture mapped for url: $url" >&2
  exit 1
fi
cp "$src" "$dest"
EOS
  chmod +x "$fake_bin/curl"
}

map_url() {
  # $1=url  $2=source fixture file
  key="$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')"
  cp "$2" "$curl_map/$key"
}

# Builds a trivial POSIX-sh "binary" fixture that exits 0 regardless of
# arguments - stands in for kind/kubectl/helm well enough for
# verify_executable()'s "$dest" version[...] checks. $2 is a distinct
# comment payload so different fixture variants produce different bytes
# (and therefore different checksums), which is what makes a
# cross-platform mix-up detectable at all.
make_exec_fixture() {
  out="$1"; tag="$2"
  printf '#!/bin/sh\n# fixture:%s\nexit 0\n' "$tag" > "$out"
  chmod +x "$out"
}

make_broken_fixture() {
  out="$1"; tag="$2"
  printf '#!/bin/sh\n# fixture:%s\nexit 1\n' "$tag" > "$out"
  chmod +x "$out"
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

run_install_tools() {
  # Runs the fixture repo's own copy of install-tools.sh with the fake
  # uname/curl first on PATH. Never the real network, never this
  # repository's real .tools/.
  (
    cd "$fixture_repo"
    PATH="$fake_bin:$PATH" CURL_MAP_DIR="$curl_map" CURL_CALLS="$curl_calls" sh scripts/lab/install-tools.sh
  )
}

run_check_prerequisites() {
  (
    cd "$fixture_repo"
    PATH="$fake_bin:$PATH" sh scripts/lab/check-prerequisites.sh
  )
}

# --- B1/B2: correct platform row is selected; the other platform's row
# for the same tool is never fetched (proves no cross-platform mix-up).
kind_darwin="$root/kind-darwin.bin"; make_exec_fixture "$kind_darwin" darwin-variant
kind_linux="$root/kind-linux.bin"; make_exec_fixture "$kind_linux" linux-variant

test_platform_selection() {
  os="$1"; arch="$2"; want_variant="$3"; label="$4"
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|darwin-arm64|kind|raw||$(sha_of "$kind_darwin")|$(sha_of "$kind_darwin")|https://example.invalid/darwin-arm64/kind
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$kind_linux")|$(sha_of "$kind_linux")|https://example.invalid/linux-amd64/kind
EOF
  map_url "https://example.invalid/darwin-arm64/kind" "$kind_darwin"
  map_url "https://example.invalid/linux-amd64/kind" "$kind_linux"

  if [ "$want_variant" = darwin-variant ]; then want_sha="$(sha_of "$kind_darwin")"; else want_sha="$(sha_of "$kind_linux")"; fi

  ok=0
  if ! FAKE_UNAME_S="$os" FAKE_UNAME_M="$arch" run_install_tools >"$root/out.log" 2>&1; then
    ok=1
  fi
  got_sha="$(sha_of "$fixture_repo/.tools/bin/kind" 2>/dev/null || echo none)"
  [ "$got_sha" = "$want_sha" ] || ok=1
  report "$ok" "$label"
}
test_platform_selection Linux x86_64 linux-variant "install-tools.sh on Linux/x86_64 installs the linux-amd64 row, not darwin-arm64"
test_platform_selection Darwin arm64 darwin-variant "install-tools.sh on Darwin/arm64 installs the darwin-arm64 row, not linux-amd64"

# --- B3: a tool with no row at all for the detected platform fails
# closed instead of silently leaving it uninstalled - even though a
# *different* tool in the same file does have a row for this platform
# (proves the check is per-tool, not just "the file has at least one
# row for this platform somewhere").
test_missing_platform_row() {
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$kind_linux")|$(sha_of "$kind_linux")|https://example.invalid/linux-amd64/kind
helm|v4.2.4|darwin-arm64|helm|raw||$(sha_of "$kind_darwin")|$(sha_of "$kind_darwin")|https://example.invalid/darwin-arm64/helm
EOF
  map_url "https://example.invalid/linux-amd64/kind" "$kind_linux"
  map_url "https://example.invalid/darwin-arm64/helm" "$kind_darwin"

  ok=0
  if FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 run_install_tools >"$root/out.log" 2>&1; then
    ok=1
  fi
  grep -qi "helm has no.*entry for detected platform linux-amd64" "$root/out.log" || ok=1
  [ -e "$fixture_repo/.tools/bin/kind" ] || ok=1
  report "$ok" "install-tools.sh fails closed when one tool (helm) has no row for the detected platform, even though another (kind) does"
}
test_missing_platform_row

# --- B4: malformed metadata rows fail closed rather than partially
# installing or crashing uninformatively.
test_malformed_url() {
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$kind_linux")|$(sha_of "$kind_linux")|
EOF
  ok=0
  if FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 run_install_tools >"$root/out.log" 2>&1; then
    ok=1
  fi
  [ ! -e "$fixture_repo/.tools/bin/kind" ] || ok=1
  report "$ok" "install-tools.sh fails closed on a row with an empty/missing URL"
}
test_malformed_url

test_malformed_checksum() {
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|linux-amd64|kind|raw||not-a-real-checksum|not-a-real-checksum|https://example.invalid/linux-amd64/kind
EOF
  map_url "https://example.invalid/linux-amd64/kind" "$kind_linux"
  ok=0
  if FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 run_install_tools >"$root/out.log" 2>&1; then
    ok=1
  fi
  grep -qi "checksum mismatch" "$root/out.log" || ok=1
  [ ! -e "$fixture_repo/.tools/bin/kind" ] || ok=1
  report "$ok" "install-tools.sh fails closed on a row with a malformed (non-matching) checksum"
}
test_malformed_checksum

# --- B5: a genuinely unsupported platform combination fails closed
# before any network access is attempted at all.
test_unsupported_platform_end_to_end() {
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$kind_linux")|$(sha_of "$kind_linux")|https://example.invalid/linux-amd64/kind
EOF
  map_url "https://example.invalid/linux-amd64/kind" "$kind_linux"

  ok=0
  if FAKE_UNAME_S=Linux FAKE_UNAME_M=aarch64 run_install_tools >"$root/out.log" 2>&1; then
    ok=1
  fi
  grep -qi "unsupported platform" "$root/out.log" || ok=1
  calls="$(wc -l < "$curl_calls" | tr -d ' ')"
  [ "$calls" = "0" ] || ok=1
  report "$ok" "install-tools.sh fails closed on an unsupported platform (Linux/aarch64) before touching the network"
}
test_unsupported_platform_end_to_end

# --- B6: idempotency - a second run against an already-correct,
# already-executable install performs zero additional downloads.
test_idempotent_second_run() {
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$kind_linux")|$(sha_of "$kind_linux")|https://example.invalid/linux-amd64/kind
EOF
  map_url "https://example.invalid/linux-amd64/kind" "$kind_linux"

  ok=0
  FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 run_install_tools >"$root/out1.log" 2>&1 || ok=1
  first_calls="$(wc -l < "$curl_calls" | tr -d ' ')"
  [ "$first_calls" = "1" ] || ok=1

  FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 run_install_tools >"$root/out2.log" 2>&1 || ok=1
  second_calls="$(wc -l < "$curl_calls" | tr -d ' ')"
  [ "$second_calls" = "1" ] || ok=1
  grep -qi "already installed" "$root/out2.log" || ok=1
  report "$ok" "install-tools.sh second run is idempotent (zero additional downloads)"
}
test_idempotent_second_run

# --- B7: a checksum-valid but non-executable binary is never trusted -
# neither skipped by idempotency nor accepted as a successful install.
test_checksum_ok_but_not_executable() {
  setup_fixture_repo
  setup_fakes
  broken="$root/kind-broken.bin"
  make_broken_fixture "$broken" broken-variant
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$broken")|$(sha_of "$broken")|https://example.invalid/linux-amd64/kind
EOF
  map_url "https://example.invalid/linux-amd64/kind" "$broken"

  ok=0
  if FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 run_install_tools >"$root/out.log" 2>&1; then
    ok=1
  fi
  grep -qi "failed to execute successfully" "$root/out.log" || ok=1
  report "$ok" "install-tools.sh rejects a checksum-valid binary that fails to execute, rather than accepting it"
}
test_checksum_ok_but_not_executable

# --- B8/B9: check-prerequisites.sh mirrors the same platform-selection
# and fail-closed behavior (read-only: no curl involved at all).
test_check_prerequisites_selects_platform() {
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|darwin-arm64|kind|raw||$(sha_of "$kind_darwin")|$(sha_of "$kind_darwin")|https://example.invalid/darwin-arm64/kind
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$kind_linux")|$(sha_of "$kind_linux")|https://example.invalid/linux-amd64/kind
EOF
  cp "$kind_linux" "$fixture_repo/.tools/bin/kind"

  ok=0
  FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 run_check_prerequisites >"$root/out.log" 2>&1 || ok=1
  report "$ok" "check-prerequisites.sh accepts a linux-amd64 install when uname reports Linux/x86_64"

  ok=0
  if FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64 run_check_prerequisites >"$root/out.log" 2>&1; then
    ok=1
  fi
  grep -qi "does not match the pinned installed checksum" "$root/out.log" || ok=1
  report "$ok" "check-prerequisites.sh rejects the same install when uname reports Darwin/arm64 (checksum belongs to the other platform)"
}
test_check_prerequisites_selects_platform

test_check_prerequisites_unsupported_platform() {
  setup_fixture_repo
  setup_fakes
  cat > "$fixture_repo/scripts/lab/tool-versions.txt" <<EOF
kind|v0.33.0|linux-amd64|kind|raw||$(sha_of "$kind_linux")|$(sha_of "$kind_linux")|https://example.invalid/linux-amd64/kind
EOF
  cp "$kind_linux" "$fixture_repo/.tools/bin/kind"

  ok=0
  if FAKE_UNAME_S=Linux FAKE_UNAME_M=aarch64 run_check_prerequisites >"$root/out.log" 2>&1; then
    ok=1
  fi
  grep -qi "unsupported platform" "$root/out.log" || ok=1
  report "$ok" "check-prerequisites.sh fails closed on an unsupported platform (Linux/aarch64)"
}
test_check_prerequisites_unsupported_platform

echo
echo "test-tool-platforms: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "test-tool-platforms: FAILED"
  exit 1
fi
echo "test-tool-platforms: OK"
