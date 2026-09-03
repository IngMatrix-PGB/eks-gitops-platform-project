#!/bin/sh
# Offline validation of the pinned External Secrets Operator chart:
# `helm lint`/`helm template` for both scoped releases (exercises the
# chart's own values.schema.json), plus the full collision/ownership
# proof in lab/eso/render.sh (25-CRD decoupling, no scoped-release
# collision, webhook/cert-controller singleton, no wildcard RBAC,
# digest-only images). Never touches a cluster, never downloads
# anything - requires the chart to already be fetched
# (`make eso-chart-fetch`) and fails closed, loudly, if it is not or
# does not match its pinned checksum (never silently skipped). Backs
# `make check-eso-chart` - a standalone target, deliberately NOT part
# of `make validate`'s dependency chain: unlike this repository's other
# `make validate` checks, this one requires a chart archive that only a
# network fetch can provide, and `.github/workflows/validate.yml` is
# outside this phase's authorized file scope to extend for that fetch.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../eso/_lib.sh
. scripts/eso/_lib.sh
require_helm
require_eso_chart

fail=0

echo "check-eso-chart: helm lint (staging values) ..."
staging_values="$(mktemp)"
production_values="$(mktemp)"
trap 'rm -f "$staging_values" "$production_values"' EXIT INT TERM
eso_write_values "staging" "true" "true" "$staging_values"
eso_write_values "production" "false" "false" "$production_values"

if ! phelm lint "$ESO_CHART_TGZ" -f "$staging_values"; then
  echo "FAIL: helm lint failed for staging values" >&2
  fail=1
fi
echo "check-eso-chart: helm lint (production values) ..."
if ! phelm lint "$ESO_CHART_TGZ" -f "$production_values"; then
  echo "FAIL: helm lint failed for production values" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-eso-chart: FAILED"
  exit 1
fi
echo "OK: helm lint passed for both scoped values files (exercises the chart's own values.schema.json)"

echo "check-eso-chart: running the full collision/ownership proof (lab/eso/render.sh) ..."
if ! sh lab/eso/render.sh; then
  echo "check-eso-chart: FAILED"
  exit 1
fi

echo "check-eso-chart: OK"
