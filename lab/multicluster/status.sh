#!/bin/sh
# Read-only report for the lab-multicluster profile: identity of every
# possible member, registration state of each spoke on the hub (cluster
# Secret present, environment label, token expiry - never the token),
# and each member's current Docker memory use. Never mutates anything.
# Backs `make lab-mc-status`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools
. lab/multicluster/_lib.sh

for m in "$LAB_MC_HUB" $LAB_MC_ALL_SPOKES; do
  lab_mc_identity "$m" || true
  mem="$(docker stats --no-stream --format '{{.MemUsage}}' "eks-gitops-${m}-control-plane" 2>/dev/null | awk '{print $1}')"
  echo "member=$m identity=$LAB_MC_IDENTITY_CASE memory=${mem:-n/a}"
done

if lab_mc_identity "$LAB_MC_HUB"; then
  for s in $LAB_MC_ALL_SPOKES; do
    if ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-$s" >/dev/null 2>&1; then
      env_label="$(ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-$s" -o jsonpath='{.metadata.labels.platform\.environment}')"
      exp="$(ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-$s" -o jsonpath='{.metadata.annotations.eks-gitops-lab-lite\.local/token-expires}')"
      echo "spoke=$s registered=yes label=$env_label token-expires=${exp:-unknown}"
    else
      echo "spoke=$s registered=no"
    fi
  done
fi
