#!/bin/sh
# Downloads and checksum-verifies the pinned External Secrets Operator
# Helm chart as an immutable GitHub Release asset into .tools/charts/.
# This is the ONLY script permitted to fetch the chart - every other
# eso/* script requires it to already be present and verified
# (require_eso_chart). Backs `make eso-chart-fetch` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/eso/_lib.sh
. scripts/eso/_lib.sh

mkdir -p .tools/charts

if [ -f "$ESO_CHART_TGZ" ]; then
  existing_sha="$(shasum -a 256 "$ESO_CHART_TGZ" | awk '{print $1}')"
  if [ "$existing_sha" = "$ESO_CHART_SHA256" ]; then
    echo "OK: $ESO_CHART_TGZ already present and checksum-verified (sha256 $existing_sha) - no download needed"
    exit 0
  fi
  echo "chart-fetch: existing $ESO_CHART_TGZ does not match the pinned checksum - re-downloading" >&2
  rm -f "$ESO_CHART_TGZ"
fi

tmpdir="$(mktemp -d ".tools/tmp.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

tmp_dest="${tmpdir}/external-secrets-${ESO_CHART_VERSION}.tgz"

echo "chart-fetch: downloading external-secrets-${ESO_CHART_VERSION} (tag helm-chart-${ESO_CHART_VERSION}) from $ESO_CHART_URL ..."
if ! curl -fsSL -o "$tmp_dest" "$ESO_CHART_URL"; then
  echo "FAIL: download failed for $ESO_CHART_URL" >&2
  exit 1
fi

actual_sha="$(shasum -a 256 "$tmp_dest" | awk '{print $1}')"
if [ "$actual_sha" != "$ESO_CHART_SHA256" ]; then
  echo "FAIL: checksum mismatch for downloaded chart - expected $ESO_CHART_SHA256, got $actual_sha" >&2
  echo "      leaving no chart at $ESO_CHART_TGZ" >&2
  exit 1
fi

mv "$tmp_dest" "$ESO_CHART_TGZ"
echo "OK: external-secrets-${ESO_CHART_VERSION} fetched and checksum-verified at $ESO_CHART_TGZ (sha256 $actual_sha)"
