#!/bin/sh
# Downloads and checksum-verifies the pinned metrics-server chart into
# .tools/charts/ (Phase 2.8.2). The only script allowed to fetch it.
# Backs `make metrics-server-chart-fetch`. Idempotent.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/metrics-server/_lib.sh

mkdir -p .tools/charts
if [ -f "$MS_CHART_TGZ" ] && [ "$(shasum -a 256 "$MS_CHART_TGZ" | awk '{print $1}')" = "$MS_CHART_SHA256" ]; then
  echo "OK: $MS_CHART_TGZ already present and checksum-verified - no download needed"
  exit 0
fi

tmpdir="$(mktemp -d ".tools/tmp.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT INT TERM
tmp_dest="${tmpdir}/metrics-server-${MS_CHART_VERSION}.tgz"
echo "chart-fetch: downloading metrics-server-${MS_CHART_VERSION} from $MS_CHART_URL ..."
curl -fsSL -o "$tmp_dest" "$MS_CHART_URL" || { echo "FAIL: download failed for $MS_CHART_URL" >&2; exit 1; }
actual="$(shasum -a 256 "$tmp_dest" | awk '{print $1}')"
if [ "$actual" != "$MS_CHART_SHA256" ]; then
  echo "FAIL: checksum mismatch - expected $MS_CHART_SHA256, got $actual; leaving no chart at $MS_CHART_TGZ" >&2
  exit 1
fi
mv "$tmp_dest" "$MS_CHART_TGZ"
echo "OK: metrics-server-${MS_CHART_VERSION} fetched and checksum-verified at $MS_CHART_TGZ"
