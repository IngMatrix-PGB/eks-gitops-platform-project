#!/bin/sh
# Downloads and checksum-verifies the pinned prometheus and grafana charts
# into .tools/charts/ (Phase 6.1b). The only script allowed to fetch
# them. Backs `make obs-chart-fetch`. Idempotent.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/observability/_lib.sh

mkdir -p .tools/charts
tmpdir="$(mktemp -d ".tools/tmp.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

# $1=destination  $2=url  $3=sha256
fetch_chart() {
  if [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$3" ]; then
    echo "OK: $1 already present and checksum-verified - no download needed"
    return 0
  fi
  fc_tmp="$tmpdir/$(basename "$1")"
  echo "chart-fetch: downloading $(basename "$1") from $2 ..."
  curl -fsSL -o "$fc_tmp" "$2" || { echo "FAIL: download failed for $2" >&2; exit 1; }
  fc_sum="$(shasum -a 256 "$fc_tmp" | awk '{print $1}')"
  if [ "$fc_sum" != "$3" ]; then
    echo "FAIL: checksum mismatch for $(basename "$1") - expected $3, got $fc_sum; leaving no chart at $1" >&2
    exit 1
  fi
  mv "$fc_tmp" "$1"
  echo "OK: $(basename "$1") fetched and checksum-verified at $1"
}

fetch_chart "$OBS_PROM_CHART_TGZ" "$OBS_PROM_CHART_URL" "$OBS_PROM_CHART_SHA256"
fetch_chart "$OBS_GRAFANA_CHART_TGZ" "$OBS_GRAFANA_CHART_URL" "$OBS_GRAFANA_CHART_SHA256"
