#!/bin/sh
# Offline validation of the pinned External Secrets Operator chart:
# `helm lint`/`helm template` for every scoped release (exercises the
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

lint_dir="$(mktemp -d)"
trap 'rm -rf "$lint_dir"' EXIT INT TERM
while IFS='|' read -r env_name ns release webhook_create cert_create; do
  [ -z "$env_name" ] && continue
  echo "check-eso-chart: helm lint ($env_name values) ..."
  eso_write_values "$env_name" "$webhook_create" "$cert_create" "$lint_dir/values-${env_name}.yaml"
  if ! phelm lint "$ESO_CHART_TGZ" -f "$lint_dir/values-${env_name}.yaml"; then
    echo "FAIL: helm lint failed for $env_name values" >&2
    fail=1
  fi
done <<EOF
$(eso_environments)
EOF

if [ "$fail" -ne 0 ]; then
  echo "check-eso-chart: FAILED"
  exit 1
fi
echo "OK: helm lint passed for every scoped values file (exercises the chart's own values.schema.json)"

echo "check-eso-chart: running the full collision/ownership proof (lab/eso/render.sh) ..."
if ! LAB_CLUSTER=lab-lite sh lab/eso/render.sh; then
  echo "check-eso-chart: FAILED"
  exit 1
fi

# Phase 2.7.4: a lab-multicluster spoke runs a single release that owns
# its own webhook/cert-controller - the same proof, for that topology.
echo "check-eso-chart: same proof for a lab-multicluster spoke (LAB_CLUSTER=dev, single release owning the singletons) ..."
if ! LAB_CLUSTER=dev sh lab/eso/render.sh; then
  echo "check-eso-chart: FAILED (spoke topology)"
  exit 1
fi

echo "check-eso-chart: OK"
