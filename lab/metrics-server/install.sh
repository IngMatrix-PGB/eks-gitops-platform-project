#!/bin/sh
# Fail-closed, idempotent install of the pinned metrics-server on one
# workload cluster (Phase 2.8.2): lab-lite, or a lab-multicluster spoke
# with LAB_CLUSTER=dev|uat|prod - never the hub. Backs
# `make metrics-server-install` and `make mc-spoke-metrics-server`.
#   absent                       -> install, wait, wait for the APIService
#   same chart + same values     -> true no-op (no helm call)
#   changed values               -> upgrade
#   other chart / not deployed   -> fail closed
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/metrics-server/_lib.sh
ms_require_workload_cluster
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }
require_helm
require_ms_chart

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
ms_write_values "$work/values.yaml"
values_sha="$(shasum -a 256 "$work/values.yaml" | awk '{print $1}')"

if ms_release_exists; then
  list_json="$(phelm list -n "$MS_NAMESPACE" -o json 2>/dev/null)"
  chart="$(printf '%s' "$list_json" | tr '{' '\n' | grep "\"name\":\"${MS_RELEASE}\"" | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')"
  status_prefix="$(phelm status "$MS_RELEASE" -n "$MS_NAMESPACE" -o json 2>/dev/null | sed 's/,"notes":.*//')"
  rel_status="$(printf '%s' "$status_prefix" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
  description="$(printf '%s' "$status_prefix" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"
  [ "$chart" = "metrics-server-${MS_CHART_VERSION}" ] || { echo "FAIL: release '$MS_RELEASE' runs chart '$chart', not the pinned metrics-server-${MS_CHART_VERSION} - refusing to reconcile automatically" >&2; exit 1; }
  [ "$rel_status" = "deployed" ] || { echo "FAIL: release '$MS_RELEASE' status '$rel_status' is not 'deployed' - refusing to reconcile automatically" >&2; exit 1; }
  if [ "$description" = "values-sha256:${values_sha}" ]; then
    echo "OK: metrics-server already installed with the pinned chart and values on '$PROJECT_CLUSTER_NAME' - no-op"
    exit 0
  fi
  echo "metrics-server-install: values changed (sha256 $values_sha) - upgrading"
else
  echo "metrics-server-install: absent on '$PROJECT_CLUSTER_NAME' - installing chart ${MS_CHART_VERSION} (image ${MS_CHART_APP_VERSION}@digest)"
fi

phelm upgrade --install "$MS_RELEASE" "$MS_CHART_TGZ" \
  --namespace "$MS_NAMESPACE" -f "$work/values.yaml" \
  --description "values-sha256:${values_sha}" --wait --timeout 5m >/dev/null

pkubectl wait --for=condition=Available "apiservice/${MS_APISERVICE}" --timeout=120s >/dev/null
echo "OK: metrics-server installed on '$PROJECT_CLUSTER_NAME'; APIService ${MS_APISERVICE} Available"
