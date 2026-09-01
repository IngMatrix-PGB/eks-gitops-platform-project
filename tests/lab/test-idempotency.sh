#!/bin/sh
# Mutating lifecycle test proving create/destroy idempotency end to
# end: create -> create -> destroy -> destroy. Backs
# `make lab-test-lifecycle` only.
#
# Safety contract:
#   - Refuses to run if the project cluster already exists (never
#     deletes a pre-existing cluster).
#   - The cleanup trap only ever targets the exact cluster THIS run
#     creates, and only if it actually created one.
#   - Uses only the project-local toolchain (.tools/bin/*) and the
#     project-local kubeconfig - never a global/ambient one.
#   - Never touches any cluster other than $PROJECT_CLUSTER_NAME.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
require_tools

if kind_cluster_exists; then
  echo "FAIL: test-idempotency: cluster '$PROJECT_CLUSTER_NAME' already exists" >&2
  echo "      refusing to run the lifecycle test against a pre-existing cluster." >&2
  echo "      Use 'make lab-test' (read-only) against it instead, or deliberately" >&2
  echo "      run 'make lab-destroy' first if you intend to re-run this test." >&2
  exit 1
fi

created_by_this_test=0
cleanup() {
  if [ "$created_by_this_test" -eq 1 ] && kind_cluster_exists; then
    echo "test-idempotency: cleanup trap - removing the cluster created by this run"
    "$KIND_BIN" delete cluster --name "$PROJECT_CLUSTER_NAME" --kubeconfig "$PROJECT_KUBECONFIG" || true
  fi
}
trap cleanup EXIT INT TERM

echo "test-idempotency: step 1 - initial 'lab-create' (cluster currently absent)"
create_exit=0
sh lab/kind/create.sh || create_exit=$?
# Mark for cleanup based on actual cluster existence, not on create.sh's
# exit code - if it created the cluster but failed a later internal
# check, the trap must still know there is something to remove.
if kind_cluster_exists; then
  created_by_this_test=1
fi
if [ "$create_exit" -ne 0 ]; then
  echo "FAIL: test-idempotency: initial 'lab-create' failed (exit $create_exit)" >&2
  exit 1
fi
echo "OK: step 1 - initial create succeeded"

echo "test-idempotency: step 2 - second 'lab-create' must be an exit-0 no-op"
sh lab/kind/create.sh
echo "OK: step 2 - second create was a no-op (exit 0)"

echo "test-idempotency: step 3 - 'lab-status' against the created cluster"
sh lab/kind/status.sh
echo "OK: step 3 - status/identity validation passed"

echo "test-idempotency: step 4 - initial 'lab-destroy'"
sh lab/kind/destroy.sh
if kind_cluster_exists; then
  echo "FAIL: test-idempotency: cluster still present after first destroy" >&2
  exit 1
fi
echo "OK: step 4 - destroy succeeded, cluster absent"

echo "test-idempotency: step 5 - second 'lab-destroy' must be an exit-0 no-op"
sh lab/kind/destroy.sh
echo "OK: step 5 - second destroy was a no-op (exit 0)"

if kind_cluster_exists; then
  echo "FAIL: test-idempotency: cluster unexpectedly present at end of test" >&2
  exit 1
fi

created_by_this_test=0
echo "test-idempotency: OK - create/create/destroy/destroy lifecycle proven idempotent; cluster left absent"
