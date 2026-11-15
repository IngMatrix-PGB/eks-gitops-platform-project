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
# Tools come from .tools/bin (make tools-install, checksum-verified); no
# GitHub Action wraps them.
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

case "${1:-}" in
  build) build ;;
  scan) scan ;;
  sbom) sbom ;;
  all) build; scan; sbom ;;
  *) echo "usage: $0 build|scan|sbom|all" >&2; exit 2 ;;
esac
