#!/bin/sh
# Read-only health/identity report for the lab-lite cluster, reachable
# exclusively through the project-local kubeconfig. Backs
# `make lab-status` only - never mutates anything.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
require_tools

check_cluster_identity || true

echo "lab-status: cluster name        : $PROJECT_CLUSTER_NAME"
echo "lab-status: kubeconfig          : $PROJECT_KUBECONFIG"
echo "lab-status: expected k8s version: $PROJECT_K8S_VERSION"
echo "lab-status: expected node image : $PROJECT_NODE_IMAGE"
echo "lab-status: identity case       : $IDENTITY_CASE"
echo "lab-status: detail              : $IDENTITY_DETAIL"

if [ "$IDENTITY_CASE" = "match" ]; then
  echo "lab-status: OK - cluster healthy and matches the pinned baseline"
  exit 0
fi

echo "lab-status: NOT OK" >&2
exit 1
