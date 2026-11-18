#!/usr/bin/env bash
# Phase 5.3a (ADR-0020): the ruleset that protects main, kept as code in
# .github/rulesets/main.json.
#
#   diff                  read-only: compare the live ruleset with the file;
#                         exit 1 when it is missing or differs
#   apply --confirm       create or update the live ruleset from the file,
#                         then diff; saves the previous live JSON first
#   enforcement STATE --confirm
#                         break-glass only (docs/runbooks/repository-
#                         governance.md): set the live ruleset to disabled
#                         or back to active, nothing else
#
# Needs gh authenticated as a repository admin (GH_TOKEN). Never run in
# CI: no workflow token can change repository settings, and none should.
# The ruleset ID is looked up by name at run time, never stored.
set -euo pipefail

RULESET_FILE=".github/rulesets/main.json"
OUT_DIR=".tools/out/governance"

die() { echo "FAIL: $*" >&2; exit 1; }
command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
[ -f "$RULESET_FILE" ] || die "$RULESET_FILE not found"

name="$(jq -r .name "$RULESET_FILE")"
repo="${GOVERNANCE_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
[ -n "$repo" ] || die "cannot tell the repository; set GOVERNANCE_REPO=owner/name"

# ID of the repository-level ruleset with the file's name; empty if none.
ruleset_id() {
  gh api "repos/$repo/rulesets?includes_parents=false" \
    --jq ".[] | select(.name == \"$name\" and .source_type == \"Repository\") | .id"
}

# Rules keyed by type, status checks sorted, only the fields the file sets.
# The live side is projected onto the file's keys so fields GitHub adds
# with defaults do not count as drift; a missing field or a rule type the
# file does not have does.
# shellcheck disable=SC2016
NORM='
def norm:
  { name, target, enforcement, conditions,
    bypass_actors: (.bypass_actors // []),
    rules: ((.rules // []) | map({(.type): (.parameters // {})}) | add // {}) }
  | if .rules.required_status_checks then
      .rules.required_status_checks.required_status_checks |= sort_by(.context)
    else . end;
def proj($f):
  . as $v
  | if ($f | type) == "object" and ($v | type) == "object"
    then reduce ($f | keys[]) as $k ({}; .[$k] = ($v[$k] | proj($f[$k])))
    else $v end;
(.[0] | norm) as $file | (.[1] | norm) as $live
| { file: ($file + {rule_types: ($file.rules | keys)}),
    live: (($live | proj($file)) + {rule_types: ($live.rules | keys)}) }
'

do_diff() {
  local id live
  id="$(ruleset_id)"
  [ -n "$id" ] || { echo "governance-diff: no ruleset named '$name' on $repo" >&2; return 1; }
  mkdir -p "$OUT_DIR"
  live="$OUT_DIR/ruleset-live.json"
  gh api "repos/$repo/rulesets/$id" > "$live"
  jq -s "$NORM" "$RULESET_FILE" "$live" > "$OUT_DIR/ruleset-compare.json"
  if jq -e '.file == .live' "$OUT_DIR/ruleset-compare.json" >/dev/null; then
    echo "governance-diff: OK - ruleset '$name' on $repo matches $RULESET_FILE"
  else
    echo "governance-diff: DRIFT - ruleset '$name' on $repo differs from $RULESET_FILE:" >&2
    diff <(jq -S .file "$OUT_DIR/ruleset-compare.json") <(jq -S .live "$OUT_DIR/ruleset-compare.json") >&2 || true
    return 1
  fi
}

need_confirm() {
  [ "${1:-}" = "--confirm" ] || die "this changes repository settings on $repo; rerun with --confirm"
}

cmd="${1:-}"
case "$cmd" in
  diff)
    do_diff
    ;;
  apply)
    need_confirm "${2:-}"
    mkdir -p "$OUT_DIR"
    id="$(ruleset_id)"
    if [ -n "$id" ]; then
      gh api "repos/$repo/rulesets/$id" > "$OUT_DIR/ruleset-before.json"
      echo "apply: updating ruleset '$name' ($repo); previous version in $OUT_DIR/ruleset-before.json"
      gh api -X PUT "repos/$repo/rulesets/$id" --input "$RULESET_FILE" > /dev/null
    else
      echo "[]" > "$OUT_DIR/ruleset-before.json"
      echo "apply: creating ruleset '$name' on $repo (none existed)"
      gh api -X POST "repos/$repo/rulesets" --input "$RULESET_FILE" > /dev/null
    fi
    do_diff
    ;;
  enforcement)
    state="${2:-}"
    case "$state" in active|disabled) : ;; *) die "usage: $0 enforcement active|disabled --confirm" ;; esac
    need_confirm "${3:-}"
    id="$(ruleset_id)"
    [ -n "$id" ] || die "no ruleset named '$name' on $repo"
    gh api -X PUT "repos/$repo/rulesets/$id" -f enforcement="$state" > /dev/null
    echo "enforcement: ruleset '$name' on $repo is now $state"
    [ "$state" = active ] && do_diff
    ;;
  *)
    echo "usage: $0 diff | apply --confirm | enforcement active|disabled --confirm" >&2
    exit 2
    ;;
esac
