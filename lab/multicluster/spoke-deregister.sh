#!/bin/sh
# Deregisters one spoke from the hub's Argo CD. Usage: sh lab/
# multicluster/spoke-deregister.sh <dev|uat|prod>. Backs
# `make mc-spoke-deregister`. Idempotent.
#
# Phase 2.7.4: when the hub's ApplicationSet (profile local-multicluster)
# has generated platform-smoke-<env> for this spoke, deleting the cluster
# Secret first would leave that Application unable to run its
# resources-finalizer (no credentials left to delete the spoke's
# workloads) - stuck in deletion. So the hub side now goes:
#   1. remove the platform.environment label from spoke-<env> - the
#      clusters generator stops selecting it and the ApplicationSet
#      deletes the Application, whose finalizer removes the workloads on
#      the spoke while the credential still works;
#   2. wait (bounded) for that Application to be gone;
#   3. delete the cluster Secret.
# With no Application for this spoke (2.7.3, or no bootstrap yet) step 2
# is an immediate no-op. Never strips a finalizer.
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

app="platform-smoke-${spoke}"
app_wait_s="${LAB_MC_DEREGISTER_TIMEOUT:-240}"
if lab_mc_identity "$LAB_MC_HUB"; then
  escaped_owner_key="$(printf '%s' "$LAB_MC_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
  secret_owner="$(ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-${spoke}" -o jsonpath="{.metadata.labels.${escaped_owner_key}}" 2>/dev/null || true)"
  if [ -n "$secret_owner" ] && [ "$secret_owner" != "$LAB_MC_OWNER_LABEL_VALUE" ]; then
    echo "FAIL: hub Secret 'spoke-${spoke}' is not owned by this registration - leaving it in place" >&2
    exit 1
  fi
  if [ "$secret_owner" = "$LAB_MC_OWNER_LABEL_VALUE" ]; then
    # 1. unselect the spoke (the label is the generator's only handle on it)
    ckubectl "$LAB_MC_HUB" -n argocd label secret "spoke-${spoke}" "${LAB_MC_ENV_LABEL_KEY}-" >/dev/null 2>&1 || true
    # 2. wait for its Application (and the Application's own cascade on
    #    the spoke) to finish while the credential is still valid
    if ckubectl "$LAB_MC_HUB" -n argocd get application "$app" >/dev/null 2>&1; then
      if ! lab_mc_identity "$spoke"; then
        echo "FAIL: Application '$app' still exists but spoke '$spoke' is not running ($LAB_MC_IDENTITY_CASE) - its finalizer cannot clean up; start the spoke and re-run" >&2
        exit 1
      fi
      echo "mc-spoke-deregister: waiting up to ${app_wait_s}s for Application '$app' to be removed (its finalizer deletes the workloads on '$spoke') ..."
      waited=0
      while ckubectl "$LAB_MC_HUB" -n argocd get application "$app" >/dev/null 2>&1; do
        if [ "$waited" -ge "$app_wait_s" ]; then
          echo "FAIL: Application '$app' was not removed within ${app_wait_s}s - the cluster Secret is kept (unlabelled) so its finalizer can still finish; inspect it and re-run" >&2
          exit 1
        fi
        sleep 3; waited=$((waited + 3))
      done
      echo "OK: Application '$app' removed after ${waited}s (workloads on '$spoke' deleted by its finalizer)"
    fi
    # 3. now the credential can go
    ckubectl "$LAB_MC_HUB" -n argocd delete secret "spoke-${spoke}" --ignore-not-found >/dev/null
  fi
  echo "OK: hub cluster Secret for '$spoke' removed (or already absent)"
else
  echo "OK: hub is not running ($LAB_MC_IDENTITY_CASE) - nothing to remove there"
fi

if lab_mc_identity "$spoke"; then
  ckubectl "$spoke" -n "$spoke" delete rolebinding,role -l "$sel" --ignore-not-found >/dev/null
  escaped_owner_key="$(printf '%s' "$LAB_MC_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
  access_owner="$(ckubectl "$spoke" get namespace "$LAB_MC_ACCESS_NS" -o jsonpath="{.metadata.labels.${escaped_owner_key}}" 2>/dev/null || true)"
  if [ "$access_owner" = "$LAB_MC_OWNER_LABEL_VALUE" ]; then
    ckubectl "$spoke" delete namespace "$LAB_MC_ACCESS_NS" --wait --timeout=90s >/dev/null
  elif ckubectl "$spoke" get namespace "$LAB_MC_ACCESS_NS" >/dev/null 2>&1; then
    echo "FAIL: namespace '$LAB_MC_ACCESS_NS' on '$spoke' is not owned by this registration - leaving it in place" >&2
    exit 1
  fi
  echo "OK: spoke '$spoke': Role/RoleBinding and ${LAB_MC_ACCESS_NS} removed (or already absent); namespace '$spoke' kept"
else
  echo "OK: spoke '$spoke' is not running ($LAB_MC_IDENTITY_CASE) - nothing to remove there"
fi
echo "mc-spoke-deregister: OK ($spoke)"
