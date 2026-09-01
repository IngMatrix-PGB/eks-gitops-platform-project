#!/bin/sh
# Read-only shape/identity test against an EXISTING project cluster.
# Backs `make lab-test`. It must never create or delete a cluster,
# install tools, or modify any kubeconfig, and it never invokes
# tests/lab/test-idempotency.sh.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
require_tools

fail=0

if ! kind_cluster_exists; then
  echo "FAIL: test-cluster-shape: cluster '$PROJECT_CLUSTER_NAME' does not exist - run 'make lab-create' first" >&2
  exit 1
fi

check_cluster_identity || true
if [ "$IDENTITY_CASE" = "match" ]; then
  echo "OK: identity - $IDENTITY_DETAIL"
else
  echo "FAIL: identity check failed - $IDENTITY_DETAIL" >&2
  fail=1
fi

count="$("$KIND_BIN" get clusters 2>/dev/null | grep -cxF "$PROJECT_CLUSTER_NAME")"
if [ "$count" = "1" ]; then
  echo "OK: exactly one cluster named '$PROJECT_CLUSTER_NAME' (found $count)"
else
  echo "FAIL: expected exactly 1 cluster named '$PROJECT_CLUSTER_NAME', found $count" >&2
  fail=1
fi

for ns in staging production argocd; do
  if pkubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "FAIL: unexpected namespace '$ns' exists - Phase 2.1 must not create it" >&2
    fail=1
  else
    echo "OK: namespace '$ns' does not exist (as expected for Phase 2.1)"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "test-cluster-shape: FAILED"
  exit 1
fi
echo "test-cluster-shape: OK"
