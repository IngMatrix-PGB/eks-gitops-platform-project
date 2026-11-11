#!/bin/sh
# Deregisters one spoke from the hub's Argo CD. Usage: sh lab/
# multicluster/spoke-deregister.sh <dev|uat|prod>. Backs
# `make mc-spoke-deregister`. Idempotent.
#
# Removes, in this order: the hub's cluster Secret spoke-<env> (Argo CD
# loses access first), then on the spoke the RoleBinding, Role, and the
# argocd-access namespace (which also invalidates every token issued for
# its ServiceAccount). The workload namespace <env> is deliberately
# kept - it may still hold workloads or ESO objects, and removing it is
# a separate, explicit decision. Only objects carrying this
# registration's owner label are deleted.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools
. lab/multicluster/_lib.sh

spoke="${1:-}"
lab_mc_require_spoke "$spoke"
sel="${LAB_MC_OWNER_LABEL_KEY}=${LAB_MC_OWNER_LABEL_VALUE}"

if lab_mc_identity "$LAB_MC_HUB"; then
  ckubectl "$LAB_MC_HUB" -n argocd delete secret -l "$sel,${LAB_MC_ENV_LABEL_KEY}=${spoke}" --ignore-not-found >/dev/null
  echo "OK: hub cluster Secret for '$spoke' removed (or already absent)"
else
  echo "OK: hub is not running ($LAB_MC_IDENTITY_CASE) - nothing to remove there"
fi

if lab_mc_identity "$spoke"; then
  ckubectl "$spoke" -n "$spoke" delete rolebinding,role -l "$sel" --ignore-not-found >/dev/null
  if ckubectl "$spoke" get namespace "$LAB_MC_ACCESS_NS" -l "$sel" -o name 2>/dev/null | grep -q .; then
    ckubectl "$spoke" delete namespace "$LAB_MC_ACCESS_NS" --wait --timeout=60s >/dev/null
  fi
  echo "OK: spoke '$spoke': Role/RoleBinding and ${LAB_MC_ACCESS_NS} removed (or already absent); namespace '$spoke' kept"
else
  echo "OK: spoke '$spoke' is not running ($LAB_MC_IDENTITY_CASE) - nothing to remove there"
fi
echo "mc-spoke-deregister: OK ($spoke)"
