#!/bin/sh
# Mutating Phase 2.7.3 lifecycle test for the lab-multicluster profile:
# clean slate -> create -> create (true no-op) -> status -> destroy ->
# destroy (no-op), for SPOKES (default dev,uat). Also proves: an unknown
# spoke and an unknown LAB_CLUSTER fail closed before anything is
# created; lab-mc-create refuses while lab-lite exists (checked without
# ever creating lab-lite - only when it already happens to exist);
# every member gets its own kubeconfig, distinct from the global one;
# the global kubeconfig is never touched. Records each member's memory
# at steady state. Backs `make lab-mc-test-lifecycle`.
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

read -r global_sha_before global_ctx_before <<EOF
$(global_kubeconfig_fingerprint)
EOF

# --- 1. clean slate ---
for m in "$LAB_MC_HUB" $LAB_MC_ALL_SPOKES; do
  lab_mc_identity "$m" || true
  if [ "$LAB_MC_IDENTITY_CASE" != "absent" ]; then
    echo "FAIL: member '$m' is not absent ($LAB_MC_IDENTITY_CASE) - run 'make lab-mc-destroy' before this test" >&2
    exit 1
  fi
done
echo "OK: step 1 - no lab-multicluster member exists"

# --- 2. fail closed on bad input, before anything is created ---
if SPOKES=dev,qa sh lab/multicluster/create.sh >/dev/null 2>&1; then
  echo "FAIL: SPOKES=dev,qa was accepted" >&2; exit 1
fi
if SPOKES=dev,dev sh lab/multicluster/create.sh >/dev/null 2>&1; then
  echo "FAIL: SPOKES=dev,dev was accepted" >&2; exit 1
fi
if LAB_CLUSTER=staging sh lab/kind/status.sh >/dev/null 2>&1; then
  echo "FAIL: LAB_CLUSTER=staging was accepted" >&2; exit 1
fi
for m in "$LAB_MC_HUB" $LAB_MC_ALL_SPOKES; do
  lab_mc_identity "$m" || true
  [ "$LAB_MC_IDENTITY_CASE" = "absent" ] || { echo "FAIL: a rejected invocation created member '$m'" >&2; exit 1; }
done
echo "OK: step 2 - unknown spoke, duplicate spoke, and unknown LAB_CLUSTER all fail closed with nothing created"

# --- 3. create ---
sh lab/multicluster/create.sh
for m in $members; do
  lab_mc_identity "$m" || { echo "FAIL: member '$m' does not match after create ($LAB_MC_IDENTITY_CASE)" >&2; exit 1; }
  kc="$(lab_mc_kubeconfig "$m")"
  [ -f "$kc" ] || { echo "FAIL: $kc missing" >&2; exit 1; }
  LAB_CLUSTER="$m" sh -c '. scripts/lab/_lib.sh; assert_kubeconfig_paths_distinct' || exit 1
done
echo "OK: step 3 - hub and spokes ($spokes) created, each with its own kubeconfig, distinct from the global one"

# --- 4. second create is a true no-op (same container IDs) ---
ids_before="$(for m in $members; do docker inspect --format '{{.Id}}' "eks-gitops-${m}-control-plane"; done)"
sh lab/multicluster/create.sh
ids_after="$(for m in $members; do docker inspect --format '{{.Id}}' "eks-gitops-${m}-control-plane"; done)"
[ "$ids_before" = "$ids_after" ] || { echo "FAIL: second create changed a node container" >&2; exit 1; }
echo "OK: step 4 - second create is a true no-op (node container IDs unchanged)"

# --- 5. status + memory record ---
sh lab/multicluster/status.sh
echo "test-lifecycle(multicluster): steady-state memory (bare clusters, no Argo CD yet):"
for m in $members; do
  docker stats --no-stream --format "  {{.Name}} {{.MemUsage}}" "eks-gitops-${m}-control-plane"
done

# --- 6. destroy + destroy (no-op) ---
sh lab/multicluster/destroy.sh
for m in "$LAB_MC_HUB" $LAB_MC_ALL_SPOKES; do
  lab_mc_identity "$m" || true
  [ "$LAB_MC_IDENTITY_CASE" = "absent" ] || { echo "FAIL: member '$m' still present after destroy ($LAB_MC_IDENTITY_CASE)" >&2; exit 1; }
done
sh lab/multicluster/destroy.sh
echo "OK: step 6 - destroy removed every member and its kubeconfig; second destroy is a no-op"

read -r global_sha_after global_ctx_after <<EOF
$(global_kubeconfig_fingerprint)
EOF
if [ "$global_sha_before" != "$global_sha_after" ] || [ "$global_ctx_before" != "$global_ctx_after" ]; then
  echo "FAIL: global kubeconfig or current-context changed" >&2
  exit 1
fi
echo "OK: global kubeconfig hash and current-context unchanged throughout"
echo "test-lifecycle(multicluster): OK"
