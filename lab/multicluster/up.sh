#!/bin/sh
# Brings the whole lab-multicluster profile up, end to end, in the only
# order that works on fresh clusters (Phase 2.7.4, ADR-0015). Backs
# `make mc-up`. Idempotent: on an already-converged lab every step is a
# no-op (no token rotation, no Helm upgrade, no re-apply).
#
#   1. create the hub + selected spokes          (lab/multicluster/create.sh)
#   2. Argo CD on the hub                        (LAB_CLUSTER=hub lab/argocd/install.sh)
#   3. repository Secret on the hub              (LAB_CLUSTER=hub lab/gitops/repo-setup.sh)
#   4. per spoke:
#      a. register with the hub - only when not registered, unlabelled,
#         or the token expires within LAB_MC_TOKEN_MIN_REMAINING_H hours
#         (default 2); otherwise left alone so the token is not rotated
#      b. ESO, one release owning its own webhook  (LAB_CLUSTER=<env> lab/eso/install.sh)
#      c. ESO source Secret - created only if absent
#      d. metrics-server (Phase 2.8.2)             (LAB_CLUSTER=<env> lab/metrics-server/install.sh)
#   5. hub bootstrap, profile local-multicluster (LAB_CLUSTER=hub lab/gitops/bootstrap.sh)
#
# Register (4a) runs before ESO (4b) on purpose: it creates the workload
# namespace the scoped ESO release watches, and ESO's CRDs then exist
# before Argo CD's first sync - R-13 does not arise in this profile.
#
# SPOKES (default dev,uat) and REVISION (default main) pass through.
# Source Secret values are read the same way `make eso-provision-source-
# secret` reads them (echo-disabled prompt, or stdin) - or, for
# unattended runs, from a mode-600 file named by MC_SOURCE_VALUE_FILE
# (the path, never the value, is the parameter). Nothing here prints a
# token or a secret value.
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
min_h="${LAB_MC_TOKEN_MIN_REMAINING_H:-2}"
case "$min_h" in ''|*[!0-9]*) echo "FAIL: LAB_MC_TOKEN_MIN_REMAINING_H must be a whole number of hours" >&2; exit 1 ;; esac

if [ -n "${MC_SOURCE_VALUE_FILE:-}" ]; then
  [ -f "$MC_SOURCE_VALUE_FILE" ] || { echo "FAIL: MC_SOURCE_VALUE_FILE does not exist" >&2; exit 1; }
  perm="$(stat -f '%Lp' "$MC_SOURCE_VALUE_FILE" 2>/dev/null || stat -c '%a' "$MC_SOURCE_VALUE_FILE")"
  [ "$perm" = "600" ] || { echo "FAIL: MC_SOURCE_VALUE_FILE must be mode 600 (is $perm)" >&2; exit 1; }
fi

echo "mc-up: [1/5] clusters (hub + $spokes) ..."
sh lab/multicluster/create.sh

echo "mc-up: [2/5] Argo CD on the hub ..."
LAB_CLUSTER=hub sh lab/argocd/install.sh

echo "mc-up: [3/5] repository Secret on the hub ..."
# Already provisioned with the local deploy key -> nothing to do, and no
# GitHub API call (repo-setup needs the owner's gh account active).
if LAB_CLUSTER=hub sh -c '. scripts/lab/_lib.sh; . scripts/argocd/_lib.sh; . scripts/gitops/_lib.sh; gitops_repo_secret_matches_local_key'; then
  echo "OK: hub repository Secret already present and matches the local deploy key - repo-setup skipped"
else
  LAB_CLUSTER=hub sh lab/gitops/repo-setup.sh
fi

threshold="$(date -u -v+"${min_h}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+${min_h} hours" +%Y-%m-%dT%H:%M:%SZ)"
escaped_env_key="$(printf '%s' "$LAB_MC_ENV_LABEL_KEY" | sed 's/\./\\./g')"
for s in $spokes; do
  echo "mc-up: [4/5] spoke '$s' ..."
  expires="$(ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-${s}" -o jsonpath='{.metadata.annotations.eks-gitops-lab-lite\.local/token-expires}' 2>/dev/null || true)"
  env_label="$(ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-${s}" -o jsonpath="{.metadata.labels.${escaped_env_key}}" 2>/dev/null || true)"
  if [ -z "$expires" ] || [ "$env_label" != "$s" ]; then
    sh lab/multicluster/spoke-register.sh "$s"
  elif [ "$expires" \< "$threshold" ]; then
    echo "mc-up: token for '$s' expires $expires (< ${min_h}h left) - rotating"
    sh lab/multicluster/spoke-register.sh "$s"
  else
    echo "OK: spoke '$s' already registered (token expires $expires) - not rotated"
  fi

  LAB_CLUSTER="$s" sh lab/eso/install.sh
  LAB_CLUSTER="$s" sh lab/metrics-server/install.sh

  if ckubectl "$s" -n "eso-source-${s}" get secret "local-backend-${s}" -o name >/dev/null 2>&1; then
    echo "OK: source Secret for '$s' already present - not read, not changed"
  elif [ -n "${MC_SOURCE_VALUE_FILE:-}" ]; then
    LAB_CLUSTER="$s" sh lab/eso/provision-source-secret.sh "$s" < "$MC_SOURCE_VALUE_FILE"
  else
    echo "mc-up: enter the source value for '$s' (input hidden):"
    LAB_CLUSTER="$s" sh lab/eso/provision-source-secret.sh "$s"
  fi
done

echo "mc-up: [5/5] hub bootstrap (profile local-multicluster) ..."
LAB_CLUSTER=hub sh lab/gitops/bootstrap.sh

echo "mc-up: OK (hub + $spokes)"
