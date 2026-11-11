#!/bin/sh
# Destroys every lab-multicluster member that exists (hub and all three
# possible spokes, regardless of SPOKES), spokes first, hub last. Each
# deletion goes through lab/kind/destroy.sh, which refuses to delete a
# cluster whose project-local kubeconfig does not identify it. Never
# touches lab-lite or any other kind cluster. Idempotent. Backs
# `make lab-mc-destroy`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools
. lab/multicluster/_lib.sh

for m in prod uat dev "$LAB_MC_HUB"; do
  LAB_CLUSTER="$m" sh lab/kind/destroy.sh
done
echo "lab-mc-destroy: OK"
