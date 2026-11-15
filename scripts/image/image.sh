#!/bin/sh
# Phase 5.1a: build, scan and SBOM for the first-party image (apps/smoke).
# The same script runs locally and in .github/workflows/image.yml, so CI
# never does anything a developer cannot reproduce with `make image-*`.
# Nothing here pushes or signs (Phase 5.1b).
#
#   scripts/image/image.sh build   docker build, then save the image as an
#                                  OCI archive (.tools/out/image/smoke.tar)
#   scripts/image/image.sh scan    trivy: the Dockerfile (misconfig) and the
#                                  archive (vulnerabilities); fails on any
#                                  HIGH/CRITICAL finding that has a fix
#   scripts/image/image.sh sbom    syft: CycloneDX SBOM of the archive
#                                  (.tools/out/image/smoke.cdx.json)
#   scripts/image/image.sh all     build + scan + sbom
#
# Phase 5.1b (multi-platform, push and keyless signing):
#   build-multi    linux/amd64 + linux/arm64 index as an OCI archive
#                  (.tools/out/image/smoke-index.tar); both platforms required
#   publish        build-multi pushed to IMAGE_REPO, tag sha-<VERSION>; writes
#                  the index reference to .tools/out/image/published.ref.
#                  CI only (or IMAGE_PUBLISH_CONFIRM=yes)
#   scan-remote    trivy on every platform of IMAGE (default: published.ref)
#   sign           cosign keyless: sign the index (recursively) and attest a
#                  CycloneDX SBOM to each platform manifest
#   verify         cosign verify + verify-attestation of IMAGE against the
#                  exact signer identity below (never a regex)
#
# Tools come from .tools/bin (make tools-install, checksum-verified); no
# third-party GitHub Action wraps them.
set -eu

[ -f scripts/lab/tool-versions.txt ] || { echo "FAIL: run from the repository root" >&2; exit 1; }

IMAGE_APP_DIR="apps/smoke"
IMAGE_NAME="eks-gitops-platform-smoke"
IMAGE_OUT=".tools/out/image"
IMAGE_ARCHIVE="$IMAGE_OUT/smoke.tar"
IMAGE_SBOM="$IMAGE_OUT/smoke.cdx.json"
# The failing threshold (TAD roadmap 5.1): any HIGH or CRITICAL finding
# with a fix available fails the build. Unfixed findings are reported,
# never silently dropped, but cannot be acted on by this repository.
IMAGE_SCAN_SEVERITY="HIGH,CRITICAL"
TRIVY_BIN=".tools/bin/trivy"
SYFT_BIN=".tools/bin/syft"
COSIGN_BIN="${COSIGN_BIN:-.tools/bin/cosign}"
IMAGE_REPO="ghcr.io/ingmatrix-pgb/eks-gitops-platform-smoke"
IMAGE_PLATFORMS="linux/amd64,linux/arm64"
IMAGE_INDEX_ARCHIVE="$IMAGE_OUT/smoke-index.tar"
IMAGE_PUBLISHED_REF="$IMAGE_OUT/published.ref"
# Pinned BuildKit for multi-platform builds (a docker-container builder),
# so neither CI nor a laptop builds with an unpinned builder image.
IMAGE_BUILDER="smoke-builder"
IMAGE_BUILDKIT="moby/buildkit:v0.34.1@sha256:99368f3e46177c6405b9740e4461d91cee004128daeecca78d4ceac50ec1da5c"
# The only identity whose signatures this project trusts: the image
# workflow on main, through GitHub's OIDC issuer. Exact match, never a
# regex. Reused by the promotion guard (Phase 5.1c).
IMAGE_SIGNER_IDENTITY="https://github.com/IngMatrix-PGB/eks-gitops-platform-project/.github/workflows/image.yml@refs/heads/main"
IMAGE_SIGNER_ISSUER="https://token.actions.githubusercontent.com"
VERSION="${VERSION:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo dev)}"

need() { [ -x "$1" ] || { echo "FAIL: $1 not found - run 'make tools-install'" >&2; exit 1; }; }

build() {
  command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not found" >&2; exit 1; }
  mkdir -p "$IMAGE_OUT"
  echo "image: building $IMAGE_NAME:$VERSION from $IMAGE_APP_DIR (tests run in the build stage) ..."
  docker build --pull --build-arg "VERSION=$VERSION" -t "$IMAGE_NAME:$VERSION" "$IMAGE_APP_DIR"
  docker save -o "$IMAGE_ARCHIVE" "$IMAGE_NAME:$VERSION"
  user="$(docker image inspect "$IMAGE_NAME:$VERSION" --format '{{.Config.User}}')"
  case "$user" in
    ""|0|0:*|root|root:*) echo "FAIL: image runs as '$user' - must be non-root" >&2; exit 1 ;;
  esac
  echo "OK: built $IMAGE_NAME:$VERSION (user $user), archive $IMAGE_ARCHIVE"
}

scan() {
  need "$TRIVY_BIN"
  [ -f "$IMAGE_ARCHIVE" ] || { echo "FAIL: $IMAGE_ARCHIVE missing - run 'make image-build' first" >&2; exit 1; }
  cache=".tools/cache/trivy"
  mkdir -p "$cache"
  echo "image: trivy config $IMAGE_APP_DIR (fail on $IMAGE_SCAN_SEVERITY) ..."
  "$TRIVY_BIN" config --cache-dir "$cache" --quiet --exit-code 1 --severity "$IMAGE_SCAN_SEVERITY" "$IMAGE_APP_DIR"
  echo "image: trivy image $IMAGE_ARCHIVE (fail on fixable $IMAGE_SCAN_SEVERITY) ..."
  "$TRIVY_BIN" image --cache-dir "$cache" --quiet --input "$IMAGE_ARCHIVE" \
    --scanners vuln --ignore-unfixed --exit-code 1 --severity "$IMAGE_SCAN_SEVERITY" \
    --ignorefile "$IMAGE_APP_DIR/.trivyignore"
  echo "image: every severity, including unfixed (informational, never fails) ..."
  "$TRIVY_BIN" image --cache-dir "$cache" --quiet --input "$IMAGE_ARCHIVE" --scanners vuln --exit-code 0
  echo "OK: no fixable $IMAGE_SCAN_SEVERITY vulnerability and no $IMAGE_SCAN_SEVERITY misconfiguration"
}

sbom() {
  need "$SYFT_BIN"
  [ -f "$IMAGE_ARCHIVE" ] || { echo "FAIL: $IMAGE_ARCHIVE missing - run 'make image-build' first" >&2; exit 1; }
  SYFT_CHECK_FOR_APP_UPDATE=false "$SYFT_BIN" scan "docker-archive:$IMAGE_ARCHIVE" -q -o "cyclonedx-json=$IMAGE_SBOM"
  grep -q '"bomFormat"' "$IMAGE_SBOM" && grep -q '"name": *"stdlib"' "$IMAGE_SBOM" \
    || { echo "FAIL: $IMAGE_SBOM is not a CycloneDX SBOM that lists the Go stdlib" >&2; exit 1; }
  echo "OK: CycloneDX SBOM at $IMAGE_SBOM ($(grep -o '"bom-ref"' "$IMAGE_SBOM" | wc -l | tr -d ' ') entries)"
}

ensure_builder() {
  if ! docker buildx inspect "$IMAGE_BUILDER" >/dev/null 2>&1; then
    docker buildx create --name "$IMAGE_BUILDER" --driver docker-container \
      --driver-opt "image=$IMAGE_BUILDKIT" >/dev/null
  fi
  docker buildx inspect --bootstrap "$IMAGE_BUILDER" >/dev/null
}

# multi_build <output-args...>: the one multi-platform build definition,
# used for the local archive and for the push.
multi_build() {
  ensure_builder
  docker buildx build --builder "$IMAGE_BUILDER" --pull \
    --platform "$IMAGE_PLATFORMS" --provenance=false --sbom=false \
    --build-arg "VERSION=$VERSION" --build-arg "REVISION=$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
    "$@" "$IMAGE_APP_DIR"
}

build_multi() {
  command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not found" >&2; exit 1; }
  mkdir -p "$IMAGE_OUT"
  echo "image: building $IMAGE_PLATFORMS index (cross-compiled, tests in the build stage) ..."
  multi_build --output "type=oci,dest=$IMAGE_INDEX_ARCHIVE"
  for plat in $(printf '%s' "$IMAGE_PLATFORMS" | tr ',' ' '); do
    arch="${plat#linux/}"
    tar -xOf "$IMAGE_INDEX_ARCHIVE" 2>/dev/null | grep -aqE "\"architecture\": ?\"$arch\"" \
      || { echo "FAIL: $IMAGE_INDEX_ARCHIVE has no $plat manifest" >&2; exit 1; }
  done
  echo "OK: OCI index with $IMAGE_PLATFORMS at $IMAGE_INDEX_ARCHIVE"
}

publish() {
  if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${IMAGE_PUBLISH_CONFIRM:-}" != "yes" ]; then
    echo "FAIL: publish runs in CI on main only; set IMAGE_PUBLISH_CONFIRM=yes to push from here on purpose" >&2
    exit 1
  fi
  mkdir -p "$IMAGE_OUT"
  meta="$IMAGE_OUT/publish-metadata.json"
  echo "image: pushing $IMAGE_PLATFORMS to $IMAGE_REPO:sha-$VERSION ..."
  multi_build --push --tag "$IMAGE_REPO:sha-$VERSION" --metadata-file "$meta"
  digest="$(grep -oE '"containerimage.digest": *"sha256:[0-9a-f]{64}"' "$meta" | grep -oE 'sha256:[0-9a-f]{64}')"
  [ -n "$digest" ] || { echo "FAIL: no index digest in $meta" >&2; exit 1; }
  printf '%s@%s\n' "$IMAGE_REPO" "$digest" > "$IMAGE_PUBLISHED_REF"
  echo "OK: published $(cat "$IMAGE_PUBLISHED_REF")"
}

# image_ref: IMAGE, else the last published reference; must be our
# repository pinned by digest.
image_ref() {
  ref="${IMAGE:-}"
  [ -n "$ref" ] || { [ -f "$IMAGE_PUBLISHED_REF" ] && ref="$(cat "$IMAGE_PUBLISHED_REF")"; }
  printf '%s' "$ref" | grep -qE "^${IMAGE_REPO}@sha256:[0-9a-f]{64}\$" \
    || { echo "FAIL: IMAGE must be ${IMAGE_REPO}@sha256:<64 hex> (got '${ref:-nothing}')" >&2; exit 1; }
  printf '%s' "$ref"
}

# platform_digests <index-ref>: "os/arch digest" per platform manifest.
platform_digests() {
  docker buildx imagetools inspect "$1" \
    --format '{{range .Manifest.Manifests}}{{.Platform.OS}}/{{.Platform.Architecture}} {{.Digest}}{{"\n"}}{{end}}' \
    | grep -E '^linux/[a-z0-9]+ sha256:[0-9a-f]{64}$'
}

scan_remote() {
  need "$TRIVY_BIN"
  ref="$(image_ref)"
  cache=".tools/cache/trivy"; mkdir -p "$cache"
  for plat in $(printf '%s' "$IMAGE_PLATFORMS" | tr ',' ' '); do
    echo "image: trivy image $ref ($plat, fail on fixable $IMAGE_SCAN_SEVERITY) ..."
    "$TRIVY_BIN" image --cache-dir "$cache" --quiet --platform "$plat" \
      --scanners vuln --ignore-unfixed --exit-code 1 --severity "$IMAGE_SCAN_SEVERITY" \
      --ignorefile "$IMAGE_APP_DIR/.trivyignore" "$ref"
  done
  echo "OK: every platform of $ref is free of fixable $IMAGE_SCAN_SEVERITY vulnerabilities"
}

sign() {
  need "$COSIGN_BIN"; need "$SYFT_BIN"
  ref="$(image_ref)"
  echo "image: cosign sign (keyless, recursive) $ref ..."
  "$COSIGN_BIN" sign --yes --recursive "$ref"
  platform_digests "$ref" > "$IMAGE_OUT/platforms.txt"
  [ "$(wc -l < "$IMAGE_OUT/platforms.txt" | tr -d ' ')" = "$(printf '%s' "$IMAGE_PLATFORMS" | tr ',' '\n' | wc -l | tr -d ' ')" ] \
    || { echo "FAIL: $ref does not hold exactly $IMAGE_PLATFORMS" >&2; exit 1; }
  while read -r plat pdigest; do
    sbom_file="$IMAGE_OUT/smoke-$(printf '%s' "$plat" | tr '/' '-').cdx.json"
    SYFT_CHECK_FOR_APP_UPDATE=false "$SYFT_BIN" scan "registry:${IMAGE_REPO}@${pdigest}" -q -o "cyclonedx-json=$sbom_file"
    echo "image: cosign attest --type cyclonedx ${IMAGE_REPO}@${pdigest} ($plat) ..."
    "$COSIGN_BIN" attest --yes --type cyclonedx --predicate "$sbom_file" "${IMAGE_REPO}@${pdigest}"
  done < "$IMAGE_OUT/platforms.txt"
  echo "OK: signed $ref and attested a CycloneDX SBOM to each platform"
}

verify() {
  need "$COSIGN_BIN"
  ref="$(image_ref)"
  echo "image: cosign verify $ref (identity $IMAGE_SIGNER_IDENTITY) ..."
  "$COSIGN_BIN" verify --certificate-identity "$IMAGE_SIGNER_IDENTITY" \
    --certificate-oidc-issuer "$IMAGE_SIGNER_ISSUER" "$ref" >/dev/null
  n=0
  while read -r plat pdigest; do
    "$COSIGN_BIN" verify-attestation --type cyclonedx \
      --certificate-identity "$IMAGE_SIGNER_IDENTITY" \
      --certificate-oidc-issuer "$IMAGE_SIGNER_ISSUER" "${IMAGE_REPO}@${pdigest}" >/dev/null
    echo "OK: $plat ${IMAGE_REPO}@${pdigest}: signed SBOM attestation verified"
    n=$((n + 1))
  done <<EOF_PLATFORMS
$(platform_digests "$ref")
EOF_PLATFORMS
  [ "$n" -ge 2 ] || { echo "FAIL: expected at least 2 platform manifests under $ref, verified $n" >&2; exit 1; }
  echo "OK: $ref is signed by the main image workflow, with SBOM attestations on all $n platforms"
}

case "${1:-}" in
  build) build ;;
  scan) scan ;;
  sbom) sbom ;;
  all) build; scan; sbom ;;
  build-multi) build_multi ;;
  publish) publish ;;
  scan-remote) scan_remote ;;
  sign) sign ;;
  verify) verify ;;
  *) echo "usage: $0 build|scan|sbom|all|build-multi|publish|scan-remote|sign|verify" >&2; exit 2 ;;
esac
