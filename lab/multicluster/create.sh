#!/bin/sh
# Creates the lab-multicluster profile (Phase 2.7.3, ADR-0015): the
# `management` hub plus the selected spokes (SPOKES, default "dev,uat";
# prod is opt-in), each a pinned kind cluster with its own kubeconfig.
# Idempotent: a member that already matches its pinned identity is a
# no-op; any other existing state fails closed. Refuses to run while
# lab-lite exists (both profiles together do not fit in the measured
# Docker memory), and refuses when Docker's free memory is below the
# estimate for the clusters still to be created - never stops or
# touches any other container. Creates clusters only: Argo CD, the
# repository Secret, and spoke registration are separate steps.
# Backs `make lab-mc-create`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools
. lab/multicluster/_lib.sh

spokes="$(lab_mc_spokes)"
members="$LAB_MC_HUB $spokes"

if "$KIND_BIN" get clusters 2>/dev/null | grep -qxF "eks-gitops-lab-lite"; then
  echo "FAIL: lab-mc-create: the lab-lite cluster (eks-gitops-lab-lite) is running - lab-lite and lab-multicluster do not fit in Docker memory together. Run 'make lab-destroy' first." >&2
  exit 1
fi

# --- classify every member before creating anything ---
to_create=""
needed_mib=0
for m in $members; do
  lab_mc_identity "$m" || true
  case "$LAB_MC_IDENTITY_CASE" in
    match) echo "lab-mc-create: '$m' already matches its pinned identity - no-op" ;;
    absent)
      to_create="${to_create:+$to_create }$m"
      if [ "$m" = "$LAB_MC_HUB" ]; then needed_mib=$((needed_mib + LAB_MC_HUB_MIB)); else needed_mib=$((needed_mib + LAB_MC_SPOKE_MIB)); fi
      ;;
    *)
      echo "FAIL: lab-mc-create: member '$m' is in state '$LAB_MC_IDENTITY_CASE' - refusing to create, adopt, or overwrite; resolve it (make lab-mc-destroy) before retrying" >&2
      exit 1
      ;;
  esac
done

if [ -z "$to_create" ]; then
  echo "lab-mc-create: no-op - hub and spokes ($spokes) already exist and match"
  exit 0
fi

free_mib="$(lab_mc_docker_free_mib)" || { echo "FAIL: could not read Docker memory" >&2; exit 1; }
if [ "${LAB_MC_SKIP_MEMORY_CHECK:-}" = "1" ]; then
  echo "lab-mc-create: WARNING - memory preflight skipped by LAB_MC_SKIP_MEMORY_CHECK=1 (free ${free_mib} MiB, estimated need ${needed_mib} MiB)"
elif [ "$free_mib" -lt "$needed_mib" ]; then
  echo "FAIL: lab-mc-create: Docker has ~${free_mib} MiB free, the clusters still to create ($to_create) need an estimated ${needed_mib} MiB. Free memory (stop other containers yourself, or raise Docker Desktop's memory limit) or select fewer spokes (SPOKES=dev,uat). Nothing was created." >&2
  exit 1
else
  echo "OK: memory preflight - ~${free_mib} MiB free, estimated need ${needed_mib} MiB for: $to_create"
fi

for m in $to_create; do
  LAB_CLUSTER="$m" sh lab/kind/create.sh
done

for m in $members; do
  if ! lab_mc_identity "$m"; then
    echo "FAIL: lab-mc-create: member '$m' failed post-create identity validation ($LAB_MC_IDENTITY_CASE)" >&2
    exit 1
  fi
done
echo "lab-mc-create: success - hub and spokes ($spokes) exist and match their pinned identity"
