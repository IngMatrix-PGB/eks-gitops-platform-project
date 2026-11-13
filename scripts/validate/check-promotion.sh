#!/usr/bin/env bash
# Phase 5.1c-1 (ADR-0017): offline guard of image promotion. Part of
# `make validate`. Checks:
#   1. every overlay (values-<env>.yaml, values-<env>-aws.yaml) sets its
#      own digest-pinned image, and both overlays of an environment hold
#      the same reference;
#   2. ledger rows (gitops/promotions/smoke.tsv) are well formed, in date
#      order, and follow the order: dev <- main, uat <- dev, prod <- uat,
#      where a uat/prod row needs an earlier row of its source
#      environment with the same reference;
#   3. an environment that runs an image from our repository has a ledger
#      row for exactly that reference;
#   4. the ledger is append-only versus PROMOTION_BASE_REF (default
#      origin/main): existing rows are never edited or removed.
# The signature itself is checked online by .github/workflows/promotion.yml.
set -euo pipefail

[ -f scripts/promote/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/promote/_lib.sh
IMAGE_REPO="$(sed -n 's/^IMAGE_REPO="\(.*\)"$/\1/p' scripts/image/image.sh)"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

# 1. overlays
declare -A env_ref
for env in $PROMOTE_ENVS; do
  read -r a b <<<"$(promote_overlays "$env")"
  ra="$(overlay_image_ref "$a")"; rb="$(overlay_image_ref "$b")"
  for pair in "$a=$ra" "$b=$rb"; do
    f="${pair%%=*}"; r="${pair#*=}"
    printf '%s' "$r" | grep -qE '^[a-z0-9][a-z0-9./_-]*@sha256:[0-9a-f]{64}$' || bad "$f: needs its own image block with a repository and a sha256 digest (got '${r:-none}')"
  done
  [ "$ra" = "$rb" ] || bad "$env: $a ($ra) and $b ($rb) must hold the same image"
  env_ref[$env]="$ra"
done

# 2. ledger rows
[ -f "$PROMOTE_LEDGER" ] || { bad "$PROMOTE_LEDGER missing"; }
rows=()
if [ -f "$PROMOTE_LEDGER" ]; then
  while IFS= read -r line; do rows+=("$line"); done < <(grep -vE '^[[:space:]]*(#|$)' "$PROMOTE_LEDGER" || true)
fi
prev_date=""
declare -A seen
for i in "${!rows[@]}"; do
  row="${rows[$i]}"
  IFS=$'\t' read -r d e r s extra <<<"$row"
  if [ -n "${extra:-}" ] || ! printf '%s' "$d" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
     || ! printf '%s' "$r" | grep -qE "^${IMAGE_REPO//./\\.}@sha256:[0-9a-f]{64}$"; then
    bad "$PROMOTE_LEDGER row $((i + 1)) is malformed: '$row' (want date<TAB>env<TAB>${IMAGE_REPO}@sha256:...<TAB>from)"
    continue
  fi
  want_src="$(promote_source_env "$e" 2>/dev/null || echo invalid)"
  [ "$s" = "$want_src" ] || bad "$PROMOTE_LEDGER row $((i + 1)): $e may only be promoted from '$want_src', not '$s'"
  [ -n "$prev_date" ] && [[ "$d" < "$prev_date" ]] && bad "$PROMOTE_LEDGER row $((i + 1)): date $d is before the previous row ($prev_date)"
  prev_date="$d"
  if [ "$s" != "main" ] && [ -z "${seen["$s|$r"]:-}" ]; then
    bad "$PROMOTE_LEDGER row $((i + 1)): $e got $r, which $s never had before it"
  fi
  seen["$e|$r"]=1
done

# 3. running images of our repository are in the ledger
for env in $PROMOTE_ENVS; do
  r="${env_ref[$env]}"
  case "$r" in
    "${IMAGE_REPO}@"*) [ -n "${seen["$env|$r"]:-}" ] || bad "$env runs $r, but $PROMOTE_LEDGER has no promotion of it into $env - use make promote" ;;
  esac
done

# 4. append-only versus the base
base="${PROMOTION_BASE_REF:-origin/main}"
if git rev-parse --verify --quiet "$base^{commit}" >/dev/null && git cat-file -e "$base:$PROMOTE_LEDGER" 2>/dev/null; then
  removed="$(git diff --unified=0 "$base" -- "$PROMOTE_LEDGER" | grep -E '^-[^-]' || true)"
  if [ -n "$removed" ]; then
    bad "$PROMOTE_LEDGER is append-only - these lines of $base were changed or removed:"
    printf '%s\n' "$removed" >&2
  else
    echo "OK: $PROMOTE_LEDGER only appends to $base"
  fi
else
  echo "OK: $PROMOTE_LEDGER is not on $base yet - append-only check starts once it is"
fi

if [ "$fail" -ne 0 ]; then echo "check-promotion: FAILED"; exit 1; fi
echo "OK: every overlay pins its own image; local and aws overlays agree (dev=${env_ref[dev]##*/}, uat=${env_ref[uat]##*/}, prod=${env_ref[prod]##*/})"
echo "OK: ${#rows[@]} ledger row(s) follow dev <- main, uat <- dev, prod <- uat; every running image of ${IMAGE_REPO} is recorded"
echo "check-promotion: OK"
