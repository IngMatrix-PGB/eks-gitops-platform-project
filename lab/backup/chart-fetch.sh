#!/bin/sh
# Downloads and checksum-verifies the pinned velero chart into
# .tools/charts/ (Phase 6.2a). The only script allowed to fetch it.
# Backs `make backup-chart-fetch`. Idempotent.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/backup/_lib.sh

mkdir -p .tools/charts
if [ -f "$BK_VELERO_CHART_TGZ" ] && [ "$(shasum -a 256 "$BK_VELERO_CHART_TGZ" | awk '{print $1}')" = "$BK_VELERO_CHART_SHA256" ]; then
  echo "OK: $BK_VELERO_CHART_TGZ already present and checksum-verified - no download needed"
  exit 0
fi
tmpdir="$(mktemp -d ".tools/tmp.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT INT TERM
curl -fsSL -o "$tmpdir/chart.tgz" "$BK_VELERO_CHART_URL" || { echo "FAIL: download failed for $BK_VELERO_CHART_URL" >&2; exit 1; }
got="$(shasum -a 256 "$tmpdir/chart.tgz" | awk '{print $1}')"
[ "$got" = "$BK_VELERO_CHART_SHA256" ] || { echo "FAIL: checksum mismatch - expected $BK_VELERO_CHART_SHA256, got $got; leaving no chart" >&2; exit 1; }
mv "$tmpdir/chart.tgz" "$BK_VELERO_CHART_TGZ"
echo "OK: velero-${BK_VELERO_CHART_VERSION} fetched and checksum-verified at $BK_VELERO_CHART_TGZ"
