#!/bin/sh
# Rotates the hub's Argo CD token for each registered spoke when it has
# less than MIN_HOURS left (default 8), or when its expiry is missing or
# unreadable, by re-running spoke-register.sh. Backs `make
# mc-spoke-rotate` and the preflight of the commands that need the
# spokes (lab/multicluster/token-preflight.sh). Never prints a token.
#
# A spoke with no hub Secret is skipped: registering it is `make
# mc-spoke-register`'s job, not rotation's. Exits 0 quietly when the hub
# is not reachable (Docker stopped), so a scheduled run does not fail
# with the lab down.
set -eu
[ -f lab/multicluster/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/lab/_lib.sh
. lab/multicluster/_lib.sh
min_hours="${MIN_HOURS:-8}"
case "$min_hours" in ''|*[!0-9]*) echo "FAIL: MIN_HOURS must be a whole number of hours (got '$min_hours')" >&2; exit 1 ;; esac
[ "$min_hours" -le 23 ] || { echo "FAIL: MIN_HOURS must be below 24 (a fresh token lasts 24h)" >&2; exit 1; }

if ! ckubectl "$LAB_MC_HUB" -n argocd get secrets -o name >/dev/null 2>&1; then
  echo "SKIP: hub not reachable - nothing rotated"
  exit 0
fi

spokes="$(SPOKES="${SPOKES:-$LAB_MC_ALL_SPOKES}" lab_mc_spokes)"
rotated=0
for s in $spokes; do
  if ! ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-$s" -o name >/dev/null 2>&1; then
    echo "SKIP: spoke '$s' is not registered (make mc-spoke-register SPOKE=$s)"
    continue
  fi
  expires="$(lab_mc_token_expiry "$s")"
  if lab_mc_token_needs_rotation "$expires" "$min_hours"; then
    echo "spoke-rotate: '$s' token expires ${expires:-unknown} (< ${min_hours}h left) - rotating"
    sh lab/multicluster/spoke-register.sh "$s" | sed -n 's/^OK: hub cluster Secret/OK: rotated - hub cluster Secret/p'
    rotated=$((rotated + 1))
  else
    echo "OK: spoke '$s' token expires $expires - not rotated"
  fi
done
echo "spoke-rotate: OK ($rotated rotated)"
