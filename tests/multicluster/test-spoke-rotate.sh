#!/bin/sh
# Accept/reject cases for the spoke token rotation decision
# (lab_mc_token_needs_rotation) and the token lifetime bound
# (lab_mc_token_duration_ok), with a fixed clock. No cluster.
# Backs `make mc-spoke-rotate-regression` (in validate).
set -eu
[ -f lab/multicluster/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/lab/_lib.sh
. lab/multicluster/_lib.sh
SPOKE_TOKEN_NOW="2026-11-26T12:00:00Z"; export SPOKE_TOKEN_NOW
pass=0; fail=0

# $1=description $2=rotate|keep $3=expires $4=hours
decide() {
  if lab_mc_token_needs_rotation "$3" "$4"; then got=rotate; else got=keep; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; fail=$((fail + 1)); fi
}
# $1=description $2=accept|reject $3=duration
duration() {
  if lab_mc_token_duration_ok "$3"; then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; fail=$((fail + 1)); fi
}

decide "a fresh token (23h left) is kept at 8h" keep "2026-11-27T11:00:00Z" 8
decide "a token with exactly 8h left is kept at 8h" keep "2026-11-26T20:00:00Z" 8
decide "a token with 7h59m left is rotated at 8h" rotate "2026-11-26T19:59:00Z" 8
decide "a token with 3h left is kept by the 2h preflight" keep "2026-11-26T15:00:00Z" 2
decide "a token with 1h left is rotated by the 2h preflight" rotate "2026-11-26T13:00:00Z" 2
decide "an expired token is rotated" rotate "2026-11-25T14:22:43Z" 2
decide "a missing expiry is rotated" rotate "" 8
decide "an unreadable expiry is rotated" rotate "tomorrow" 8
decide "an expiry with an offset instead of Z is rotated" rotate "2026-11-27T11:00:00+00:00" 8

duration "24h (the default) is accepted" accept 24h
duration "10m (the TokenRequest minimum) is accepted" accept 10m
duration "6h is accepted" accept 6h
duration "59m is accepted" accept 59m
duration "25h is refused" reject 25h
duration "720h is refused" reject 720h
duration "9m is refused" reject 9m
duration "an empty value is refused" reject ""
duration "seconds are refused" reject 600s

echo ""
echo "test-spoke-rotate: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-spoke-rotate: FAILED"; exit 1; }
echo "test-spoke-rotate: OK"
