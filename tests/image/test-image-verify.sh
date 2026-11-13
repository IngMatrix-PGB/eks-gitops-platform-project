#!/bin/sh
# Phase 5.1b: offline test of scripts/image/image.sh verify, publish's
# guard and IMAGE validation. The real signature can only be produced on
# main (GitHub OIDC), so this pins what can drift without it: the exact
# signer identity and issuer every cosign call receives, which
# references are verified (the index, then every platform manifest with
# a CycloneDX attestation), and that any cosign failure fails the
# command. Fake cosign and docker binaries, no network, no registry.
# Backs `make image-test-verify` (in `make validate`).
set -eu

[ -f scripts/image/image.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

repo="ghcr.io/ingmatrix-pgb/eks-gitops-platform-smoke"
identity="https://github.com/IngMatrix-PGB/eks-gitops-platform-project/.github/workflows/image.yml@refs/heads/main"
issuer="https://token.actions.githubusercontent.com"
hex() { printf "$1%.0s" $(seq 1 64); }
idx="sha256:$(hex a)"; amd="sha256:$(hex b)"; arm="sha256:$(hex c)"

mkdir -p "$root/bin"
# docker: answers only `buildx imagetools inspect`, with $FAKE_PLATFORMS.
cat > "$root/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$FAKE_LOG"
case "$*" in
  "buildx imagetools inspect"*) printf '%b' "$FAKE_PLATFORMS" ;;
  *) echo "fake docker: unexpected call: $*" >&2; exit 97 ;;
esac
EOF
# cosign: logs its argv (one line per call); fails when the argv matches
# $FAKE_COSIGN_FAIL_ON.
cat > "$root/bin/cosign" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_COSIGN_LOG"
if [ -n "${FAKE_COSIGN_FAIL_ON:-}" ]; then
  case "$*" in *"$FAKE_COSIGN_FAIL_ON"*) echo "fake cosign: no matching signatures" >&2; exit 1 ;; esac
fi
exit 0
EOF
chmod +x "$root/bin/docker" "$root/bin/cosign"

two_platforms="linux/amd64 $amd\nlinux/arm64 $arm\n"
run_verify() {
  : > "$root/cosign.log"; : > "$root/docker.log"
  env PATH="$root/bin:$PATH" COSIGN_BIN="$root/bin/cosign" FAKE_LOG="$root/docker.log" \
    FAKE_COSIGN_LOG="$root/cosign.log" FAKE_PLATFORMS="${PLATS:-$two_platforms}" \
    FAKE_COSIGN_FAIL_ON="${FAIL_ON:-}" IMAGE="$1" \
    sh scripts/image/image.sh verify > "$root/out" 2>&1
}

# --- positive: exact flags, index + each platform ---
if run_verify "$repo@$idx"; then
  want="$root/want"
  {
    echo "verify --certificate-identity $identity --certificate-oidc-issuer $issuer $repo@$idx"
    echo "verify-attestation --type cyclonedx --certificate-identity $identity --certificate-oidc-issuer $issuer $repo@$amd"
    echo "verify-attestation --type cyclonedx --certificate-identity $identity --certificate-oidc-issuer $issuer $repo@$arm"
  } > "$want"
  if diff -u "$want" "$root/cosign.log" > "$root/diff"; then
    ok "verify calls cosign exactly 3 times: the index, then each platform's CycloneDX attestation, all with the exact main-workflow identity and GitHub OIDC issuer"
  else
    bad "cosign calls differ from the pinned contract:"; cat "$root/diff" >&2
  fi
else
  bad "verify failed on a valid reference: $(cat "$root/out")"
fi

# --- negatives ---
expect_fail() {
  desc="$1" reason="$2"
  if [ "$rc" -eq 0 ]; then bad "accepted: $desc"
  elif grep -q -- "$reason" "$root/out"; then ok "rejected: $desc"
  else bad "$desc: failed for the wrong reason: $(cat "$root/out")"; fi
}
rc=0; FAIL_ON="verify --certificate-identity" run_verify "$repo@$idx" || rc=$?
expect_fail "index signature not from the main workflow" "no matching signatures"
rc=0; FAIL_ON="$arm" run_verify "$repo@$idx" || rc=$?
expect_fail "arm64 SBOM attestation missing" "no matching signatures"
rc=0; PLATS="linux/amd64 $amd\n" run_verify "$repo@$idx" || rc=$?
expect_fail "an index with only one platform" "expected at least 2 platform manifests"
rc=0; run_verify "ghcr.io/someone-else/eks-gitops-platform-smoke@$idx" || rc=$?
expect_fail "another repository" "IMAGE must be"
rc=0; run_verify "$repo:sha-0123456789ab" || rc=$?
expect_fail "a tag instead of a digest" "IMAGE must be"
rc=0; run_verify "$repo@sha256:$(printf 'a%.0s' $(seq 1 63))" || rc=$?
expect_fail "a truncated digest" "IMAGE must be"
[ -s "$root/cosign.log" ] && bad "cosign was called for an invalid IMAGE" || ok "no cosign call for an invalid IMAGE"

# --- publish refuses to run outside CI without explicit confirmation ---
: > "$root/docker.log"
if env -u GITHUB_ACTIONS PATH="$root/bin:$PATH" FAKE_LOG="$root/docker.log" FAKE_PLATFORMS="" \
     sh scripts/image/image.sh publish > "$root/out" 2>&1; then
  bad "publish ran outside CI without IMAGE_PUBLISH_CONFIRM=yes"
elif grep -q 'CI on main only' "$root/out" && [ ! -s "$root/docker.log" ]; then
  ok "publish refuses to push from a laptop unless IMAGE_PUBLISH_CONFIRM=yes (docker never called)"
else
  bad "publish failed for the wrong reason or called docker: $(cat "$root/out")"
fi

if [ "$fail" -ne 0 ]; then echo "image-test-verify: FAILED"; exit 1; fi
echo "image-test-verify: OK"
