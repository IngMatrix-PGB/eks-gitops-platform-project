#!/bin/sh
# Phase 5.1c-1 (ADR-0017): promote apps/smoke into one environment by
# digest. dev takes a digest signed on main; uat takes dev's current
# image; prod takes uat's. Nothing else is accepted.
#
#   make promote ENV=dev DIGEST=sha256:<64 hex>
#   make promote ENV=uat            (DIGEST optional; must equal dev's)
#   make promote ENV=prod           (DIGEST optional; must equal uat's)
#
# Before editing anything it verifies the image (scripts/image/image.sh
# verify: keyless signature by the main image workflow + a CycloneDX SBOM
# attestation per platform). It edits only the image block of the
# environment's two overlays (local and aws) and appends one ledger row.
# It never commits, pushes or opens a pull request: the promotion PR is
# the human review gate.
set -eu

[ -f scripts/promote/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/promote/_lib.sh
IMAGE_REPO="$(sed -n 's/^IMAGE_REPO="\(.*\)"$/\1/p' scripts/image/image.sh)"
[ -n "$IMAGE_REPO" ] || { echo "FAIL: cannot read IMAGE_REPO from scripts/image/image.sh" >&2; exit 1; }

env="${ENV:-}"
src_env="$(promote_source_env "$env" 2>/dev/null)" || { echo "FAIL: ENV must be one of: $PROMOTE_ENVS" >&2; exit 1; }
digest="${DIGEST:-}"
if [ -n "$digest" ]; then
  printf '%s' "$digest" | grep -qE '^sha256:[0-9a-f]{64}$' || { echo "FAIL: DIGEST must be sha256:<64 hex>" >&2; exit 1; }
fi

if [ "$src_env" = "main" ]; then
  [ -n "$digest" ] || { echo "FAIL: dev needs DIGEST=sha256:... (the digest the image workflow published from main)" >&2; exit 1; }
  ref="${IMAGE_REPO}@${digest}"
else
  set -- $(promote_overlays "$src_env")
  src_ref="$(overlay_image_ref "$1")"
  [ "$src_ref" = "$(overlay_image_ref "$2")" ] || { echo "FAIL: $1 and $2 disagree - fix $src_env first" >&2; exit 1; }
  case "$src_ref" in
    "${IMAGE_REPO}@"*) : ;;
    *) echo "FAIL: $src_env runs '$src_ref', not an image from ${IMAGE_REPO} - promote $src_env first" >&2; exit 1 ;;
  esac
  if [ -n "$digest" ] && [ "${IMAGE_REPO}@${digest}" != "$src_ref" ]; then
    echo "FAIL: $env may only take $src_env's image ($src_ref), not ${IMAGE_REPO}@${digest}" >&2; exit 1
  fi
  ref="$src_ref"
fi

set -- $(promote_overlays "$env")
if [ "$(overlay_image_ref "$1")" = "$ref" ] && [ "$(overlay_image_ref "$2")" = "$ref" ]; then
  echo "OK: $env already runs $ref - nothing to do"
  exit 0
fi

echo "promote: verifying $ref (signature + SBOM attestations, main workflow identity) ..."
IMAGE="$ref" sh scripts/image/image.sh verify || { echo "FAIL: $ref did not verify - not promoted" >&2; exit 1; }

repo="${ref%@*}"; dg="${ref#*@}"
for f in "$1" "$2"; do
  tmp="$(mktemp)"
  awk -v repo="$repo" -v dg="$dg" '
    /^image:[[:space:]]*$/ { inimg = 1; print; next }
    inimg && /^[^[:space:]#]/ { inimg = 0 }
    inimg && /^  repository:/ { print "  repository: " repo; next }
    inimg && /^  digest:/ { print "  digest: \"" dg "\""; next }
    { print }
  ' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
  [ "$(overlay_image_ref "$f")" = "$ref" ] || { echo "FAIL: could not set the image in $f" >&2; exit 1; }
done
printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%d)" "$env" "$ref" "$src_env" >> "$PROMOTE_LEDGER"

echo "OK: promoted $env to $ref (from $src_env)"
echo "    changed: $1, $2, $PROMOTE_LEDGER"
echo "    next: review 'git diff', commit, and open the promotion PR (the review is the gate)"
