#!/bin/sh
# Downloads and checksum-verifies the pinned Argo CD Helm chart as an
# immutable GitHub Release asset into .tools/charts/. This is the ONLY
# script permitted to fetch the chart - every other argocd/* script
# requires it to already be present and verified (require_argocd_chart).
# Backs `make argocd-chart-fetch` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh

mkdir -p .tools/charts

if [ -f "$ARGOCD_CHART_TGZ" ]; then
  existing_sha="$(shasum -a 256 "$ARGOCD_CHART_TGZ" | awk '{print $1}')"
  if [ "$existing_sha" = "$ARGOCD_CHART_SHA256" ]; then
    echo "OK: $ARGOCD_CHART_TGZ already present and checksum-verified (sha256 $existing_sha) - no download needed"
    exit 0
  fi
  echo "chart-fetch: existing $ARGOCD_CHART_TGZ does not match the pinned checksum - re-downloading" >&2
  rm -f "$ARGOCD_CHART_TGZ"
fi

tmpdir="$(mktemp -d ".tools/tmp.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

tmp_dest="${tmpdir}/argo-cd-${ARGOCD_CHART_VERSION}.tgz"

echo "chart-fetch: downloading argo-cd-${ARGOCD_CHART_VERSION} from $ARGOCD_CHART_URL ..."
if ! curl -fsSL -o "$tmp_dest" "$ARGOCD_CHART_URL"; then
  echo "FAIL: download failed for $ARGOCD_CHART_URL" >&2
  exit 1
fi

actual_sha="$(shasum -a 256 "$tmp_dest" | awk '{print $1}')"
if [ "$actual_sha" != "$ARGOCD_CHART_SHA256" ]; then
  echo "FAIL: checksum mismatch for downloaded chart - expected $ARGOCD_CHART_SHA256, got $actual_sha" >&2
  echo "      leaving no chart at $ARGOCD_CHART_TGZ" >&2
  exit 1
fi

mv "$tmp_dest" "$ARGOCD_CHART_TGZ"
echo "OK: argo-cd-${ARGOCD_CHART_VERSION} fetched and checksum-verified at $ARGOCD_CHART_TGZ (sha256 $actual_sha)"
