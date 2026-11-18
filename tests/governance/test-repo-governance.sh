#!/bin/sh
# Regression tests for Phase 5.3a (ADR-0020):
#   - scripts/validate/check-repo-governance.sh, run unmodified against
#     throwaway copies of this repository's workflows, Makefile and
#     ruleset, each with one mutation;
#   - scripts/ci/changed-paths.sh, run against a throwaway git repository.
# Backs `make check-repo-governance-regression`. Touches nothing outside
# one mktemp -d root.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$here/scripts/validate/check-repo-governance.sh"
paths_script="$here/scripts/ci/changed-paths.sh"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM

fail=0
pass=0
report() {
  if [ "$1" -eq 0 ]; then echo "OK: $2"; pass=$((pass + 1)); else echo "FAIL: $2" >&2; fail=$((fail + 1)); fi
}

n=0
# $1=description  $2=accept|reject  $3=setup function (gets the fixture dir)
run_case() {
  n=$((n + 1))
  fx="$root/case$n"
  mkdir -p "$fx/.github"
  cp -R "$here/.github/workflows" "$here/.github/rulesets" "$fx/.github/"
  cp "$here/Makefile" "$fx/Makefile"
  "$3" "$fx"
  if (cd "$fx" && bash "$checker" >"$fx.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then
    report 0 "$1"
  else
    report 1 "$1 (expected $2, got $got)"
    sed 's/^/    /' "$fx.out" >&2
  fi
}

# $1=file  $2=sed expression; a mutation that changes nothing fails loudly.
mutate() {
  cp "$1" "$1.orig"
  sed -i.bak -e "$2" "$1" && rm -f "$1.bak"
  if cmp -s "$1" "$1.orig"; then
    echo "FAIL: mutation '$2' changed nothing in $1" >&2
    exit 1
  fi
  rm -f "$1.orig"
}
# $1=fixture  $2=jq filter applied to the ruleset
mutate_rs() {
  f="$1/.github/rulesets/main.json"
  jq "$2" "$f" > "$f.new" && mv "$f.new" "$f"
}

real() { :; }
run_case "the real ruleset, workflows and Makefile are accepted" accept real

# --- ruleset ---------------------------------------------------------------
rs_bypass() { mutate_rs "$1" '.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]'; }
run_case "a bypass actor is rejected" reject rs_bypass
rs_disabled() { mutate_rs "$1" '.enforcement = "disabled"'; }
run_case "a disabled ruleset is rejected" reject rs_disabled
rs_wildcard() { mutate_rs "$1" '.conditions.ref_name.include = ["~DEFAULT_BRANCH", "refs/heads/*"]'; }
run_case "a target other than exactly refs/heads/main is rejected" reject rs_wildcard
rs_no_nff() { mutate_rs "$1" '.rules |= map(select(.type != "non_fast_forward"))'; }
run_case "a ruleset that allows force pushes is rejected" reject rs_no_nff
rs_squash() { mutate_rs "$1" '(.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods) = ["merge", "squash"]'; }
run_case "squash merges in the ruleset are rejected" reject rs_squash
rs_threads() { mutate_rs "$1" '(.rules[] | select(.type == "pull_request") | .parameters.required_review_thread_resolution) = false'; }
run_case "unresolved review threads allowed is rejected" reject rs_threads
rs_not_strict() { mutate_rs "$1" '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = false'; }
run_case "status checks that do not require an up-to-date branch are rejected" reject rs_not_strict
rs_any_app() { mutate_rs "$1" '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0]) |= del(.integration_id)'; }
run_case "a required check any app could satisfy (no integration_id) is rejected" reject rs_any_app
rs_drop_check() { mutate_rs "$1" '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "emulator"))'; }
run_case "dropping a workflow's only required check is rejected" reject rs_drop_check
rs_ghost() { mutate_rs "$1" '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) += [{context: "lint", integration_id: 15368}]'; }
run_case "a required check that no job produces is rejected" reject rs_ghost

# --- workflows -------------------------------------------------------------
wf_rename() { mutate "$1/.github/workflows/terraform.yml" 's#^    name: emulator$#    name: terraform emulator#'; }
run_case "renaming a required job without the ruleset is rejected" reject wf_rename
wf_pr_paths() { mutate "$1/.github/workflows/promotion.yml" 's#^    branches: \[main\]$#    branches: [main]\n    paths:\n      - "gitops/promotions/**"#'; }
run_case "a paths filter back on the pull_request trigger is rejected" reject wf_pr_paths
wf_fail_closed() { mutate "$1/.github/workflows/image.yml" "s#relevant != 'false' }}#relevant == 'true' }}#"; }
run_case "a required job skipped unless the paths job says true (fail-closed skip) is rejected" reject wf_fail_closed
wf_other_if() { mutate "$1/.github/workflows/validate.yml" 's#^    name: validate$#    name: validate\n    if: github.actor != '"'"'dependabot[bot]'"'"'#'; }
run_case "a required job with another skip condition is rejected" reject wf_other_if
wf_list_drift() { mutate "$1/.github/workflows/terraform.yml" "/^            'Makefile' \\\\\$/d"; }
run_case "a paths job list that differs from on.push.paths is rejected" reject wf_list_drift
wf_list_self() { mutate "$1/.github/workflows/promotion.yml" "s#^            '.github/workflows/promotion.yml' \\\\\$#            'docs/**' \\\\#"; }
run_case "a paths job list without the workflow itself is rejected" reject wf_list_self
wf_no_script() { mutate "$1/.github/workflows/promotion.yml" 's#bash scripts/ci/changed-paths.sh#bash scripts/ci/other.sh#'; }
run_case "a changes job that does not call changed-paths.sh is rejected" reject wf_no_script
wf_dup_name() { mutate "$1/.github/workflows/promotion.yml" 's#^    name: verify promoted images$#    name: validate#'; }
run_case "two jobs answering the same required check are rejected" reject wf_dup_name
wf_new_pr() {
  cat > "$1/.github/workflows/lint.yml" <<'EOF'
name: lint
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  lint:
    name: lint
    runs-on: ubuntu-24.04
    steps:
      - run: "true"
EOF
}
run_case "a new pull request workflow with no required job is rejected" reject wf_new_pr

# --- Makefile --------------------------------------------------------------
mk_no_diff() { mutate "$1/Makefile" 's#^	@bash scripts/governance/ruleset.sh diff$#	@true#'; }
run_case "a Makefile without the governance-diff target is rejected" reject mk_no_diff
mk_not_validated() { mutate "$1/Makefile" 's#^\(validate:.*\) check-repo-governance \(.*\)$#\1 \2#'; }
run_case "make validate without check-repo-governance is rejected" reject mk_not_validated

# --- changed-paths.sh ------------------------------------------------------
repo="$root/git"
mkdir -p "$repo/apps/smoke" "$repo/docs"
(
  cd "$repo"
  git init -q -b main
  git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
  base="$(git rev-parse HEAD)"
  echo x > docs/readme.md
  git add . && git -c user.name=t -c user.email=t@example.invalid commit -q -m docs
  docs_head="$(git rev-parse HEAD)"
  echo y > apps/smoke/main.go
  git add . && git -c user.name=t -c user.email=t@example.invalid commit -q -m app
  app_head="$(git rev-parse HEAD)"
  printf '%s %s %s\n' "$base" "$docs_head" "$app_head" > "$root/shas"
)
read -r base docs_head app_head < "$root/shas"

cp_out() { # $1=expected output line  $2=description, rest: env assignments + args
  want="$1"; desc="$2"; shift 2
  outf="$root/gh_output"; : > "$outf"
  if (cd "$repo" && env GITHUB_OUTPUT="$outf" "$@" >/dev/null 2>&1) && [ "$(cat "$outf")" = "$want" ]; then
    report 0 "$desc"
  else
    report 1 "$desc (output: '$(cat "$outf")')"
  fi
}
cp_out "relevant=false" "changed-paths: a docs-only PR is not relevant to apps/**" \
  EVENT_NAME=pull_request BASE_SHA="$base" HEAD_SHA="$docs_head" bash "$paths_script" 'apps/**'
cp_out "relevant=true" "changed-paths: a PR that touches apps/smoke is relevant to apps/**" \
  EVENT_NAME=pull_request BASE_SHA="$base" HEAD_SHA="$app_head" bash "$paths_script" 'apps/**'
cp_out "relevant=true" "changed-paths: a push always runs the job" \
  EVENT_NAME=push bash "$paths_script" 'apps/**'
cp_out "relevant=true" "changed-paths: workflow_dispatch always runs the job" \
  EVENT_NAME=workflow_dispatch bash "$paths_script" 'apps/**'

cp_fails() { # $1=description, rest: env assignments + args
  desc="$1"; shift
  outf="$root/gh_output"; : > "$outf"
  if (cd "$repo" && env GITHUB_OUTPUT="$outf" "$@" >/dev/null 2>&1); then
    report 1 "$desc (it succeeded)"
  elif [ -s "$outf" ]; then
    report 1 "$desc (it failed but wrote '$(cat "$outf")')"
  else
    report 0 "$desc"
  fi
}
cp_fails "changed-paths: a PR without base SHA fails and answers nothing (the job then runs)" \
  EVENT_NAME=pull_request HEAD_SHA="$app_head" bash "$paths_script" 'apps/**'
cp_fails "changed-paths: an unknown base commit fails and answers nothing" \
  EVENT_NAME=pull_request BASE_SHA="$(printf '%040d' 7)" HEAD_SHA="$app_head" bash "$paths_script" 'apps/**'
cp_fails "changed-paths: no pattern is a usage error" \
  EVENT_NAME=pull_request BASE_SHA="$base" HEAD_SHA="$app_head" bash "$paths_script"

echo ""
echo "test-repo-governance: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "test-repo-governance: FAILED"
  exit 1
fi
echo "test-repo-governance: OK"
