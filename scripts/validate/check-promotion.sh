#!/usr/bin/env bash
# Phase 5.1c-1 (ADR-0017): offline guard of image promotion. Part of
# `make validate`. Phase 6.3c (ADR-0023): run once per first-party app
# (PROMOTE_APPS in scripts/promote/_lib.sh), each with its own overlays
# and ledger gitops/promotions/<app>.tsv. Per app:
#   1. every overlay sets its own digest-pinned image, and the overlays of
#      an environment hold the same reference (smoke: local and aws). A
#      notes environment may have no overlay at all (notes not there yet);
#   2. ledger rows are well formed, in date order, and follow the order:
#      dev <- main, uat <- dev, prod <- uat, where a uat/prod row needs an
#      earlier row of its source environment with the same reference;
#   3. an environment that runs an image from the app's repository has a
#      ledger row for exactly that reference;
#   4. the ledger is append-only versus PROMOTION_BASE_REF (default
#      origin/main): existing rows are never edited or removed.
# And across apps (when gitops/bootstrap/values.yaml is present): an
# environment runs notes exactly when the notes ApplicationSet lists it,
# and every such environment also lists postgres.
# The signature itself is checked online by .github/workflows/promotion.yml.
set -euo pipefail

[ -f scripts/promote/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/promote/_lib.sh
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
base="${PROMOTION_BASE_REF:-origin/main}"
declare -A runs   # "<app>|<env>" -> reference (empty: not deployed)

check_app() {
  local app="$1" env a r f ra pair i row d e s extra want_src prev_date="" removed
  promote_use_app "$app" || { bad "unknown app $app"; return; }
  declare -A env_ref=() seen=()
  # 1. overlays
  for env in $PROMOTE_ENVS; do
    ra=""; local first=1 present=0
    for f in $(promote_overlays "$env"); do
      if [ ! -f "$f" ]; then
        [ "$app" = smoke ] && bad "$f is missing"
        continue
      fi
      present=1
      r="$(overlay_image_ref "$f")"
      printf '%s' "$r" | grep -qE '^[a-z0-9][a-z0-9./_-]*@sha256:[0-9a-f]{64}$' || bad "$f: needs its own image block with a repository and a sha256 digest (got '${r:-none}')"
      if [ "$first" = 1 ]; then ra="$r"; first=0
      elif [ "$r" != "$ra" ]; then bad "$env: the $app overlays $(promote_overlays "$env") must hold the same image"; fi
    done
    env_ref[$env]="$ra"
    runs["$app|$env"]="$ra"
  done

  # 2. ledger rows
  local rows=()
  if [ -f "$PROMOTE_LEDGER" ]; then
    while IFS= read -r row; do rows+=("$row"); done < <(grep -vE '^[[:space:]]*(#|$)' "$PROMOTE_LEDGER" || true)
  elif [ "$app" = smoke ]; then
    bad "$PROMOTE_LEDGER missing"
  fi
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

  # 3. running images of the app's repository are in its ledger
  for env in $PROMOTE_ENVS; do
    r="${env_ref[$env]}"
    case "$r" in
      "${IMAGE_REPO}@"*) [ -n "${seen["$env|$r"]:-}" ] || bad "$env runs $r, but $PROMOTE_LEDGER has no promotion of it into $env - use make promote APP=$app" ;;
    esac
  done

  # 4. append-only versus the base
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
  echo "OK: $app: ${#rows[@]} ledger row(s); dev=${env_ref[dev]:-none} uat=${env_ref[uat]:-none} prod=${env_ref[prod]:-none}" | sed 's#ghcr.io/ingmatrix-pgb/##g'
}

for app in $PROMOTE_APPS; do check_app "$app"; done

# 5. the notes ApplicationSet and the notes overlays agree; postgres follows notes
bs="gitops/bootstrap/values.yaml"
if [ -f "$bs" ]; then
  yq=".tools/bin/yq"
  [ -x "$yq" ] || { echo "FAIL: $yq not found - run 'make tools-install'" >&2; exit 1; }
  listed() { "$yq" -r ".components[] | select(.name == \"$1\") | (.environments // [])[]" "$bs" | tr '\n' ' '; }
  notes_envs=" $(listed notes)"; pg_envs=" $(listed postgres)"
  for env in $PROMOTE_ENVS; do
    on="${runs["notes|$env"]:-}"
    case "$notes_envs" in *" $env "*) [ -n "$on" ] || bad "$bs lists notes in $env, but no promoted notes overlay exists there - make promote APP=notes ENV=$env" ;;
      *) [ -z "$on" ] || bad "$env has a notes overlay, but $bs does not list notes in $env" ;; esac
    case "$notes_envs" in *" $env "*) case "$pg_envs" in *" $env "*) : ;; *) bad "$bs lists notes in $env without postgres" ;; esac ;; esac
  done
  echo "OK: notes runs exactly where $bs lists it (${notes_envs# }), postgres alongside (${pg_envs# })"
fi

if [ "$fail" -ne 0 ]; then echo "check-promotion: FAILED"; exit 1; fi
echo "check-promotion: OK"
