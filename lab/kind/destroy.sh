#!/bin/sh
# Deletes ONLY the exact project cluster, verified by name against
# `kind get clusters` first. Always passes both --name and --kubeconfig
# explicitly - never --all, never a wildcard/discovered list, never a
# fallback to the global kubeconfig. No-op (exit 0) if the cluster
# does not exist. Backs `make lab-destroy` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
require_tools

if ! kind_cluster_exists; then
  echo "lab-destroy: no-op - cluster '$PROJECT_CLUSTER_NAME' does not exist"
  exit 0
fi

# Never fall back to an ambient/global kubeconfig: if the project-local
# kubeconfig is missing or does not identify this exact cluster, stop
# with diagnostics rather than guessing.
if [ ! -f "$PROJECT_KUBECONFIG" ]; then
  echo "FAIL: lab-destroy: cluster '$PROJECT_CLUSTER_NAME' exists but $PROJECT_KUBECONFIG is missing" >&2
  echo "      refusing to delete without a validated project-local kubeconfig." >&2
  exit 1
fi

if ! kubeconfig_points_to_project_cluster; then
  echo "FAIL: lab-destroy: $PROJECT_KUBECONFIG does not identify context '$PROJECT_KIND_CONTEXT'" >&2
  echo "      refusing to delete - kubeconfig identity could not be validated." >&2
  exit 1
fi

echo "lab-destroy: deleting cluster '$PROJECT_CLUSTER_NAME' ..."
"$KIND_BIN" delete cluster \
  --name "$PROJECT_CLUSTER_NAME" \
  --kubeconfig "$PROJECT_KUBECONFIG"

if kind_cluster_exists; then
  echo "FAIL: lab-destroy: cluster '$PROJECT_CLUSTER_NAME' still present after delete" >&2
  exit 1
fi

# The kubeconfig at $PROJECT_KUBECONFIG was already confirmed above to
# identify exclusively this cluster - once the cluster is gone, that
# file describes nothing and would otherwise leave an "orphaned
# kubeconfig" identity state blocking a future 'lab-create'. Remove it
# so the end state is the same clean "absent" state as if it had never
# been created.
rm -f "$PROJECT_KUBECONFIG"

echo "lab-destroy: success - cluster '$PROJECT_CLUSTER_NAME' removed"
