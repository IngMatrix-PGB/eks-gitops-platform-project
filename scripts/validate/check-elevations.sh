#!/bin/sh
# Phase 4d (ADR-0025): time-bound elevation, checked in CI. Backs
# `make check-elevations` (in validate, so every pull request runs it).
#
# terraform/envs/identity-center/elevations.auto.tfvars.json lists the
# grants beyond standing access. Terraform's own validation refuses an
# entry without an expiry or longer than 8 hours; this check adds what
# only the current time can tell:
#   - an entry whose expires_at has passed fails, so an expired grant
#     cannot stay in main: the next pull request removes it, and that
#     change's apply removes it from AWS;
#   - an entry starting more than 7 days ahead fails: elevation is for
#     now, not a standing grant booked in advance.
# ELEVATIONS_FILE and ELEVATIONS_NOW (RFC 3339, UTC) override the file and
# the clock, for the regression tests only.
set -eu
[ -d terraform/envs/identity-center ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
file="${ELEVATIONS_FILE:-terraform/envs/identity-center/elevations.auto.tfvars.json}"
[ -f "$file" ] || { echo "FAIL: $file is missing - it must exist, with \"elevations\": [] when nobody is elevated" >&2; exit 1; }

python3 -I - "$file" "${ELEVATIONS_NOW:-}" <<'PY'
import datetime as dt, json, sys
path, now_s = sys.argv[1], sys.argv[2]
def parse(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
now = parse(now_s) if now_s else dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
try:
    doc = json.load(open(path))
except ValueError as e:
    print(f"FAIL: {path} is not valid JSON ({e})", file=sys.stderr); sys.exit(1)
if set(doc) != {"elevations"} or not isinstance(doc["elevations"], list):
    print(f"FAIL: {path} must hold exactly one key, \"elevations\", a list", file=sys.stderr); sys.exit(1)
fail = 0
for i, e in enumerate(doc["elevations"]):
    key = f"{e.get('group')}/{e.get('permission_set')}/{e.get('account')}"
    try:
        start, end = parse(e["starts_at"]), parse(e["expires_at"])
    except (KeyError, TypeError, ValueError):
        print(f"FAIL: elevation {i} ({key}): starts_at and expires_at must be UTC times like 2026-11-25T14:00:00Z", file=sys.stderr); fail = 1; continue
    if end <= now:
        print(f"FAIL: elevation {key} expired at {e['expires_at']} - remove it from {path} (the apply of that change removes it from AWS)", file=sys.stderr); fail = 1
    elif start - now > dt.timedelta(days=7):
        print(f"FAIL: elevation {key} starts at {e['starts_at']}, more than 7 days ahead - request it closer to the time", file=sys.stderr); fail = 1
    else:
        print(f"OK: elevation {key} active or upcoming, until {e['expires_at']} (reason: {e.get('reason', '')})")
if not doc["elevations"]:
    print("OK: no elevation in effect - standing access only")
sys.exit(fail)
PY
echo "check-elevations: OK"
