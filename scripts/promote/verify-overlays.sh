#!/bin/sh
# Phase 5.1c-1: online check behind .github/workflows/promotion.yml. Every
# distinct image of our repository that an overlay points at must verify
# (scripts/image/image.sh verify: keyless signature by the main image
# workflow + a CycloneDX SBOM attestation per platform). Images of other
# repositories (podinfo during the transition) are reported, not
# verified - check-promotion keeps them out of the promotion ledger.
set -eu

[ -f scripts/promote/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/promote/_lib.sh
IMAGE_REPO="$(sed -n 's/^IMAGE_REPO="\(.*\)"$/\1/p' scripts/image/image.sh)"

refs="$(for env in $PROMOTE_ENVS; do for f in $(promote_overlays "$env"); do overlay_image_ref "$f"; done; done | sort -u)"
n=0
for ref in $refs; do
  case "$ref" in
    "${IMAGE_REPO}@"*)
      IMAGE="$ref" sh scripts/image/image.sh verify
      n=$((n + 1)) ;;
    *) echo "note: $ref is not from ${IMAGE_REPO} - not ours to verify" ;;
  esac
done
echo "OK: $n image(s) of ${IMAGE_REPO} referenced by the overlays verified"
