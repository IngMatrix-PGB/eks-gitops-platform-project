#!/bin/sh
# Phase 5.1c-1: online check behind .github/workflows/promotion.yml. Every
# distinct image of our repositories that an overlay points at must verify
# (scripts/image/image.sh verify: keyless signature by the main image
# workflow + a CycloneDX SBOM attestation per platform). Images of other
# repositories are reported, not verified - check-promotion keeps them out
# of the promotion ledgers. Phase 6.3c: every app in PROMOTE_APPS.
set -eu

[ -f scripts/promote/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/promote/_lib.sh

total=0
for app in $PROMOTE_APPS; do
  promote_use_app "$app"
  refs="$(for env in $PROMOTE_ENVS; do for f in $(promote_overlays "$env"); do overlay_image_ref "$f"; done; done | sort -u)"
  n=0
  for ref in $refs; do
    case "$ref" in
      "${IMAGE_REPO}@"*)
        IMAGE_APP="$PROMOTE_APP" IMAGE="$ref" sh scripts/image/image.sh verify
        n=$((n + 1)) ;;
      *) echo "note: $ref is not from ${IMAGE_REPO} - not ours to verify" ;;
    esac
  done
  echo "OK: $n image(s) of ${IMAGE_REPO} referenced by the $app overlays verified"
  total=$((total + n))
done
echo "OK: $total first-party image(s) verified"
