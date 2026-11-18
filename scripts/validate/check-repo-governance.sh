#!/usr/bin/env bash
# Phase 5.3a (ADR-0020): offline guard of the ruleset that protects main
# (.github/rulesets/main.json) and of the workflows it requires. Part of
# `make validate`. It cannot see the live ruleset; `make governance-diff`
# compares that one with the file.
#
#   1. the ruleset targets refs/heads/main only, is active, has no bypass
#      actor, blocks deletion and force pushes, requires a pull request
#      (0 approvals, threads resolved, merge commits only) and strict
#      status checks, each pinned to GitHub Actions (integration 15368);
#   2. every required check is the `name:` of exactly one job, in a
#      workflow that runs on every pull request (no `paths` filter on the
#      trigger), so a required check always reports;
#   3. a required job may be skipped only through the paths job: either
#      no `if:`, or `needs: changes` with the fail-open condition, and
#      the workflow's `changes` job calls scripts/ci/changed-paths.sh;
#   4. that path list names the workflow itself and changed-paths.sh, and
#      equals `on.push.paths` when the workflow has one;
#   5. every workflow that runs on pull requests has a required job;
#   6. `make governance-diff` and this check are wired into the Makefile.
set -euo pipefail

RULESET=".github/rulesets/main.json"
GATE="\${{ !cancelled() && needs.changes.outputs.relevant != 'false' }}"
ACTIONS_APP=15368

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
command -v jq >/dev/null || { echo "FAIL: jq not found" >&2; exit 1; }

# --- 1. the ruleset file --------------------------------------------------
if ! jq -e . "$RULESET" >/dev/null 2>&1; then
  bad "$RULESET is missing or not valid JSON"
  exit 1
fi
rs_need() { jq -e "$2" "$RULESET" >/dev/null || bad "$RULESET: $1"; }
rs_need "name must be main, target branch, enforcement active" \
  '.name == "main" and .target == "branch" and .enforcement == "active"'
rs_need "must target exactly refs/heads/main" \
  '.conditions == {ref_name: {include: ["refs/heads/main"], exclude: []}}'
rs_need "bypass_actors must be an empty list (no one, owner included)" \
  '.bypass_actors == []'
rs_need "rules must be exactly deletion, non_fast_forward, pull_request, required_status_checks" \
  '[.rules[].type] | sort == ["deletion", "non_fast_forward", "pull_request", "required_status_checks"]'
rs_need "pull_request must require a PR with 0 approvals, resolved threads and merge commits only" \
  '.rules[] | select(.type == "pull_request") | .parameters
   | .required_approving_review_count == 0 and .required_review_thread_resolution == true
     and .allowed_merge_methods == ["merge"]'
rs_need "status checks must be strict (branch up to date) and enforced on create" \
  '.rules[] | select(.type == "required_status_checks") | .parameters
   | .strict_required_status_checks_policy == true and .do_not_enforce_on_create == false'
rs_need "every required check must be pinned to GitHub Actions (integration_id $ACTIONS_APP)" \
  "[.rules[] | select(.type == \"required_status_checks\") | .parameters.required_status_checks[]
    | .integration_id == $ACTIONS_APP] | length > 0 and all"
rs_need "required check names must be unique and non-empty" \
  '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]
   | length > 0 and (map(length > 0) | all) and (unique | length) == length'

contexts=()
while IFS= read -r c; do contexts+=("$c"); done < <(jq -r \
  '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "$RULESET")

# --- workflow facts -------------------------------------------------------
# One line per fact, tab-separated:
#   pr <0|1> <paths-on-pr 0|1>     push-path <p>     changes-arg <p>
#   job <id> <name> <needs> <if>
wf_facts() {
  awk -v q="'" '
    function strip(s) { sub(/^[ ]+/, "", s); sub(/[ ]+$/, "", s); gsub("^[\"" q "]|[\"" q "]$", "", s); return s }
    /^on:/ { sect = "on"; next }
    /^jobs:/ { sect = "jobs"; next }
    /^[^ #]/ { sect = "" }
    sect == "on" && /^  [a-z_]+:/ { trig = $1; sub(/:.*/, "", trig); if (trig == "pull_request") pr = 1; inpaths = 0; next }
    sect == "on" && trig == "pull_request" && /^    paths(-ignore)?:/ { prpaths = 1 }
    sect == "on" && trig == "push" && /^    paths:/ { inpaths = 1; next }
    sect == "on" && trig == "push" && inpaths && /^      - / { line = $0; sub(/^      - /, "", line); print "push-path\t" strip(line); next }
    sect == "on" && /^    [a-z]/ { inpaths = 0 }
    sect == "jobs" && /^  [A-Za-z0-9_-]+:[ ]*$/ { flush(); id = $1; sub(/:$/, "", id); name = id; needs = "-"; cond = "-"; inargs = 0; next }
    sect == "jobs" && /^    name: / { line = $0; sub(/^    name: /, "", line); name = strip(line) }
    sect == "jobs" && /^    needs: / { line = $0; sub(/^    needs: /, "", line); needs = strip(line) }
    sect == "jobs" && /^    if: / { line = $0; sub(/^    if: /, "", line); cond = line; sub(/[ ]+$/, "", cond) }
    sect == "jobs" && id == "changes" && /bash scripts\/ci\/changed-paths\.sh/ { inargs = 1; calls = 1; next }
    sect == "jobs" && inargs && $0 ~ ("^[ ]+" q "[^" q "]+" q "( [\\\\])?$") { line = $0; sub(/ \\$/, "", line); print "changes-arg\t" strip(line); next }
    sect == "jobs" && inargs { inargs = 0 }
    function flush() { if (id != "") print "job\t" id "\t" name "\t" needs "\t" cond }
    END { flush(); print "pr\t" (pr ? 1 : 0) "\t" (prpaths ? 1 : 0); print "calls\t" (calls ? 1 : 0) }
  ' "$1"
}

shopt -s nullglob
wfs=(.github/workflows/*.yml .github/workflows/*.yaml)
declare -A found_in=()
for wf in "${wfs[@]}"; do
  facts="$(wf_facts "$wf")"
  pr_line="$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "pr"')"
  on_pr="$(printf '%s' "$pr_line" | cut -f2)"
  pr_paths="$(printf '%s' "$pr_line" | cut -f3)"
  [ "$on_pr" = 1 ] || continue
  [ "$pr_paths" = 0 ] || bad "$wf: on.pull_request has a paths filter; a required check from it would never report on other PRs (move the paths to the changes job)"

  has_required=0
  has_changes=0
  while IFS=$'\t' read -r _ id name needs cond; do
    [ "$id" = changes ] && has_changes=1
    for c in "${contexts[@]}"; do
      [ "$name" = "$c" ] || continue
      has_required=1
      found_in["$c"]="${found_in[$c]:-}$wf:$id "
      if [ "$cond" != "-" ]; then
        { [ "$needs" = changes ] && [ "$cond" = "$GATE" ]; } \
          || bad "$wf: required job '$name' may be skipped only by 'needs: changes' with 'if: $GATE' (found needs '$needs', if '$cond')"
      fi
    done
  done < <(printf '%s\n' "$facts" | awk -F'\t' '$1 == "job"')
  [ "$has_required" = 1 ] || bad "$wf: runs on pull requests but none of its jobs is a required check in $RULESET"

  if printf '%s\n' "$facts" | awk -F'\t' '$1 == "job" && $5 != "-" && $4 == "changes"' | grep -q .; then
    [ "$has_changes" = 1 ] || bad "$wf: a job needs 'changes' but there is no changes job"
  fi
  if [ "$has_changes" = 1 ]; then
    printf '%s\n' "$facts" | grep -qx $'calls\t1' || bad "$wf: the changes job must call scripts/ci/changed-paths.sh"
    args="$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "changes-arg" {print $2}' | sort)"
    push="$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "push-path" {print $2}' | sort)"
    [ -n "$args" ] || bad "$wf: the changes job lists no paths"
    printf '%s\n' "$args" | grep -qxF "$wf" || bad "$wf: the changes job must list the workflow itself"
    printf '%s\n' "$args" | grep -qxF "scripts/ci/changed-paths.sh" || bad "$wf: the changes job must list scripts/ci/changed-paths.sh"
    if [ -n "$push" ] && [ "$args" != "$push" ]; then
      bad "$wf: the changes job paths differ from on.push.paths:
$(diff <(printf '%s\n' "$push") <(printf '%s\n' "$args") || true)"
    fi
  fi
done

for c in "${contexts[@]}"; do
  n="$(printf '%s' "${found_in[$c]:-}" | wc -w | tr -d ' ')"
  case "$n" in
    1) : ;;
    0) bad "required check '$c' is not the name of any job in a workflow that runs on every pull request (it would never report)" ;;
    *) bad "required check '$c' is the name of $n jobs (${found_in[$c]}); it must be unique" ;;
  esac
done

# --- 6. wiring ------------------------------------------------------------
grep -Eq '^governance-diff:' Makefile && grep -Eq '^	@bash scripts/governance/ruleset\.sh diff$' Makefile \
  || bad "Makefile: target governance-diff must run scripts/governance/ruleset.sh diff"
grep -Eq '^validate:.* check-repo-governance( |$)' Makefile \
  || bad "Makefile: validate must depend on check-repo-governance"

if [ "$fail" -ne 0 ]; then
  echo "check-repo-governance: FAILED" >&2
  exit 1
fi
echo "OK: ruleset main is active with no bypass, ${#contexts[@]} required check(s) pinned to GitHub Actions; each is one job in a workflow that runs on every PR, skippable only through its paths job"
