#!/bin/sh
# Phase 4d (ADR-0025): accept/reject cases for scripts/validate/
# check-elevations.sh, with a fixed clock (ELEVATIONS_NOW) and throwaway
# files. No cluster, no AWS. Backs `make check-elevations-regression`.
set -eu
[ -f scripts/validate/check-elevations.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0; n=0
NOW="2026-11-25T12:00:00Z"

# $1=description $2=accept|reject $3=file content
run_case() {
  n=$((n + 1)); f="$root/case$n.json"; printf '%s\n' "$3" > "$f"
  if ELEVATIONS_FILE="$f" ELEVATIONS_NOW="$NOW" sh scripts/validate/check-elevations.sh > "$f.out" 2>&1; then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$f.out" >&2; fail=$((fail + 1)); fi
}
e() { # group permission_set account starts expires
  printf '{"group":"%s","permission_set":"%s","account":"%s","starts_at":"%s","expires_at":"%s","reason":"regression fixture"}' "$1" "$2" "$3" "$4" "$5"
}

if sh scripts/validate/check-elevations.sh >/dev/null 2>&1; then echo "OK: the committed file passes"; pass=$((pass + 1)); else
  echo "FAIL: the committed file fails check-elevations" >&2; fail=$((fail + 1)); fi
run_case "no elevation passes" accept '{"elevations": []}'
run_case "an active elevation passes" accept "{\"elevations\": [$(e breakglass BreakGlass prod 2026-11-25T11:00:00Z 2026-11-25T13:00:00Z)]}"
run_case "an upcoming elevation passes" accept "{\"elevations\": [$(e platform-admins PlatformAdmin prod 2026-11-26T08:00:00Z 2026-11-26T12:00:00Z)]}"
run_case "an expired elevation is rejected" reject "{\"elevations\": [$(e breakglass BreakGlass prod 2026-11-25T08:00:00Z 2026-11-25T11:59:59Z)]}"
run_case "an elevation expiring exactly now is rejected" reject "{\"elevations\": [$(e breakglass BreakGlass prod 2026-11-25T08:00:00Z 2026-11-25T12:00:00Z)]}"
run_case "one expired among active ones is rejected" reject "{\"elevations\": [$(e breakglass BreakGlass prod 2026-11-25T11:00:00Z 2026-11-25T13:00:00Z), $(e platform-admins PlatformAdmin prod 2026-11-24T08:00:00Z 2026-11-24T10:00:00Z)]}"
run_case "an elevation booked more than 7 days ahead is rejected" reject "{\"elevations\": [$(e platform-admins PlatformAdmin prod 2026-12-03T08:00:00Z 2026-12-03T10:00:00Z)]}"
run_case "a time without a zone is rejected" reject "{\"elevations\": [$(e breakglass BreakGlass prod 2026-11-25T11:00:00 2026-11-25T13:00:00)]}"
run_case "a missing expiry is rejected" reject '{"elevations": [{"group":"breakglass","permission_set":"BreakGlass","account":"prod","starts_at":"2026-11-25T11:00:00Z","reason":"no end"}]}'
run_case "another top-level key is rejected" reject '{"elevations": [], "standing": []}'
run_case "invalid JSON is rejected" reject '{"elevations": ['

echo ""
echo "test-elevations: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-elevations: FAILED"; exit 1; }
echo "test-elevations: OK"
