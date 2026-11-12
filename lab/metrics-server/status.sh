#!/bin/sh
# Read-only status of metrics-server on one workload cluster (Phase
# 2.8.2): release, Deployment, APIService, and whether node/pod metrics
# are actually served. Backs `make metrics-server-status`. Exits non-zero
# when any of them is missing or unhealthy.
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

fail=0
if ms_release_exists; then echo "OK: release '$MS_RELEASE' present in $MS_NAMESPACE"; else echo "FAIL: release '$MS_RELEASE' absent" >&2; fail=1; fi
av="$(pkubectl -n "$MS_NAMESPACE" get deployment "$MS_RELEASE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
if [ "${av:-0}" -ge 1 ] 2>/dev/null; then echo "OK: Deployment $MS_RELEASE Available ($av)"; else echo "FAIL: Deployment $MS_RELEASE not Available" >&2; fail=1; fi
apis="$(pkubectl get apiservice "$MS_APISERVICE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
if [ "$apis" = "True" ]; then echo "OK: APIService $MS_APISERVICE Available"; else echo "FAIL: APIService $MS_APISERVICE Available='$apis'" >&2; fail=1; fi
nodes="$(pkubectl top nodes --no-headers 2>/dev/null | grep -c . || true)"
if [ "${nodes:-0}" -ge 1 ]; then echo "OK: node metrics served ($nodes node(s))"; else echo "FAIL: no node metrics yet" >&2; fail=1; fi
[ "$fail" -eq 0 ] || exit 1
echo "metrics-server-status: OK ($PROJECT_CLUSTER_NAME)"
