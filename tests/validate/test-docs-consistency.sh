#!/bin/sh
# Regression tests for scripts/validate/check-docs-consistency.sh
# (Phase 7a): the checker, unmodified, against throwaway copies of
# README, the TAD, the ADRs and the runbooks, each with one mutation.
# Backs `make check-docs-consistency-regression`. Touches nothing outside
# one mktemp -d root.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$here/scripts/validate/check-docs-consistency.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0; n=0
tad=docs/architecture/technical-architecture.md
run_case() { # $1=description $2=accept|reject $3=setup function
  n=$((n + 1)); fx="$root/case$n"
  mkdir -p "$fx/docs/architecture"
  cp "$here/README.md" "$fx/"
  cp "$here/$tad" "$fx/$tad"
  cp -R "$here/docs/adr" "$here/docs/runbooks" "$fx/docs/"
  "$3" "$fx"
  if (cd "$fx" && bash "$checker" > "$fx.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$fx.out" >&2; fail=$((fail + 1)); fi
}
mutate() { # $1=file $2=sed expression; a mutation that changes nothing fails loudly
  cp "$1" "$1.orig"; sed -i.bak -e "$2" "$1" && rm -f "$1.bak"
  if cmp -s "$1" "$1.orig"; then echo "FAIL: mutation '$2' changed nothing in $1" >&2; exit 1; fi
  rm -f "$1.orig"
}

real() { :; }
run_case "the real README, TAD, ADRs and runbooks are accepted" accept real

tad_case() { mutate "$1/$tad" 's/| Platform scope and repository boundaries | Accepted |/| PLATFORM Scope And Repository Boundaries (Phase 0) | Accepted |/'; }
run_case "letter case and a trailing parenthetical in a TAD title are accepted" accept tad_case
tad_title() { mutate "$1/$tad" 's/| Environment topology | Accepted |/| Environment layout | Accepted |/'; }
run_case "a TAD ADR title that differs from the ADR is rejected" reject tad_title
readme_status() { mutate "$1/README.md" 's/^\(| \[0004\].*| \)Accepted |$/\1Proposed |/'; }
run_case "a README ADR status that differs from the ADR is rejected" reject readme_status
readme_missing() { mutate "$1/README.md" '/^| \[0023\](docs\/adr\//d'; }
run_case "an ADR missing from README's table is rejected" reject readme_missing
tad_dup() { mutate "$1/$tad" '/^| \[ADR-0002\]/p'; }
run_case "an ADR listed twice in the TAD is rejected" reject tad_dup
adr_superseded() { mutate "$1/docs/adr/0008-standard-workload-before-sso.md" 's/^\*\*Status:\*\* Accepted$/**Status:** Superseded/'; }
run_case "an ADR whose own status changed while both tables kept the old one is rejected" reject adr_superseded
adr_new() { cp "$1/docs/adr/0023-reference-application.md" "$1/docs/adr/0024-something-new.md"; sed -i.bak 's/^# ADR-0023:/# ADR-0024:/' "$1/docs/adr/0024-something-new.md"; rm -f "$1/docs/adr/0024-something-new.md.bak"; }
run_case "a new ADR file listed in neither table is rejected" reject adr_new

readme_phase() { mutate "$1/README.md" 's/^\(| 6\.3 | .*| \)Implemented (6.3a–6.3e) |$/\1In progress |/'; }
run_case "a README phase status that differs from the roadmap is rejected" reject readme_phase
tad_phase() { mutate "$1/$tad" 's/^\(  - \*\*6\.2 — [^*]*:\*\* \)implemented/\1in progress/'; }
run_case "a roadmap status that differs from README is rejected" reject tad_phase
readme_unknown() { mutate "$1/README.md" 's/^\(| 7d | .*\)$/\1\
| 9.9 | A phase the roadmap does not have | Implemented |/'; }
run_case "a README phase the roadmap does not have is rejected" reject readme_unknown
readme_no_top() { mutate "$1/README.md" '/^| Phase 7 | /d'; }
run_case "a top-level roadmap phase without a README row is rejected" reject readme_no_top
readme_no_word() { mutate "$1/README.md" 's/^\(| 6\.4b | .*| \)Not started |$/\1Soon |/'; }
run_case "a README status with no recognized status word is rejected" reject readme_no_word
readme_done_word() { mutate "$1/README.md" 's/^\(| Phase 5 | .*| \)Complete |$/\1Implemented |/'; }
run_case "implemented and complete are the same status" accept readme_done_word

runbook_unlinked() { printf '# Runbook: unlinked\n' > "$1/docs/runbooks/unlinked.md"; }
run_case "a runbook linked from neither README nor the TAD is rejected" reject runbook_unlinked

echo ""
echo "test-docs-consistency: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-docs-consistency: FAILED"; exit 1; }
echo "test-docs-consistency: OK"
