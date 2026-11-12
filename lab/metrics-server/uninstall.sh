#!/bin/sh
# Idempotent uninstall of metrics-server from one workload cluster (Phase
# 2.8.2). Removes only the Helm release (and with it the APIService and
# RBAC it created); kube-system itself is never touched. An HPA that
# remains reports ScalingActive=False until metrics-server returns.
# Backs `make metrics-server-uninstall`.
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

if ms_release_exists; then
  phelm uninstall "$MS_RELEASE" -n "$MS_NAMESPACE" --wait --timeout 5m >/dev/null
  echo "OK: release '$MS_RELEASE' uninstalled from '$PROJECT_CLUSTER_NAME'"
else
  echo "OK: release '$MS_RELEASE' already absent on '$PROJECT_CLUSTER_NAME' - no-op"
fi
