#!/bin/sh
# Phase 5.1c-1 (ADR-0017): promote a first-party image into one
# environment by digest. dev takes a digest signed on main; uat takes
# dev's current image; prod takes uat's. Nothing else is accepted.
#
#   make promote [APP=smoke|notes] ENV=dev DIGEST=sha256:<64 hex>
#   make promote [APP=...] ENV=uat     (DIGEST optional; must equal dev's)
#   make promote [APP=...] ENV=prod    (DIGEST optional; must equal uat's)
#
# Phase 6.3c (ADR-0023): APP selects the app (default smoke); each has its
# own overlays and ledger (scripts/promote/_lib.sh). A notes overlay must
# exist before its first promotion (it carries the environment's notes
# configuration); promotion adds or replaces only its image block.
#
# Before editing anything it verifies the image (scripts/image/image.sh
# verify: keyless signature by the main image workflow + a CycloneDX SBOM
# attestation per platform). It edits only the image block of the
# environment's overlays and appends one ledger row. It never commits,
# pushes or opens a pull request: the promotion PR is the human review
# gate.
set -eu

[ -f scripts/promote/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/promote/_lib.sh
app="${APP:-smoke}"
promote_use_app "$app" || { echo "FAIL: APP must be one of: $PROMOTE_APPS" >&2; exit 1; }

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
  src_ref="$(overlays_ref "$src_env")"
  [ "$src_ref" != MISMATCH ] || { echo "FAIL: the $app overlays of $src_env disagree ($(promote_overlays "$src_env")) - fix $src_env first" >&2; exit 1; }
  case "$src_ref" in
    "${IMAGE_REPO}@"*) : ;;
    *) echo "FAIL: $src_env runs '${src_ref:-no $app}', not an image from ${IMAGE_REPO} - promote $src_env first" >&2; exit 1 ;;
  esac
  if [ -n "$digest" ] && [ "${IMAGE_REPO}@${digest}" != "$src_ref" ]; then
    echo "FAIL: $env may only take $src_env's image ($src_ref), not ${IMAGE_REPO}@${digest}" >&2; exit 1
  fi
  ref="$src_ref"
fi

targets="$(promote_overlays "$env")"
for f in $targets; do
  [ -f "$f" ] || { echo "FAIL: $f does not exist - add the $env $app overlay (its configuration) first, then promote" >&2; exit 1; }
done
if [ "$(overlays_ref "$env")" = "$ref" ]; then
  echo "OK: $app in $env already runs $ref - nothing to do"
  exit 0
fi

echo "promote: verifying $ref (signature + SBOM attestations, main workflow identity) ..."
IMAGE_APP="$PROMOTE_APP" IMAGE="$ref" sh scripts/image/image.sh verify || { echo "FAIL: $ref did not verify - not promoted" >&2; exit 1; }

repo="${ref%@*}"; dg="${ref#*@}"
for f in $targets; do
  tmp="$(mktemp)"
  if grep -qE '^image:[[:space:]]*$' "$f"; then
    awk -v repo="$repo" -v dg="$dg" '
      /^image:[[:space:]]*$/ { inimg = 1; print; next }
      inimg && /^[^[:space:]#]/ { inimg = 0 }
      inimg && /^  repository:/ { print "  repository: " repo; next }
      inimg && /^  digest:/ { print "  digest: \"" dg "\""; next }
      { print }
    ' "$f" > "$tmp"
  else
    # first promotion of this overlay: the image block goes right after
    # the leading comment header
    awk -v repo="$repo" -v dg="$dg" '
      !done && !/^#/ { print "image:"; print "  repository: " repo; print "  digest: \"" dg "\""; print ""; done = 1 }
      { print }
      END { if (!done) { print "image:"; print "  repository: " repo; print "  digest: \"" dg "\"" } }
    ' "$f" > "$tmp"
  fi
  cat "$tmp" > "$f"; rm -f "$tmp"
  [ "$(overlay_image_ref "$f")" = "$ref" ] || { echo "FAIL: could not set the image in $f" >&2; exit 1; }
done
printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%d)" "$env" "$ref" "$src_env" >> "$PROMOTE_LEDGER"

echo "OK: promoted $app in $env to $ref (from $src_env)"
echo "    changed: $targets $PROMOTE_LEDGER"
echo "    next: review 'git diff', commit, and open the promotion PR (the review is the gate)"
