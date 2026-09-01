#!/bin/sh
# Uninstalls the Argo CD Helm release. CRDs are retained by chart design
# (crds.keep: true in values-lab.yaml) - this script never deletes them.
# The 'argocd' namespace is deleted only if this bootstrap owns it (the
# eks-gitops-lab-lite.local/owner=argocd-bootstrap label) AND an
# exhaustive inventory shows nothing unexpected remains. Idempotent: a
# second run with no release/namespace present is a no-op. Backs
# `make argocd-uninstall`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm

if argocd_release_exists; then
  echo "argocd-uninstall: uninstalling release '$ARGOCD_RELEASE_NAME' ..."
  # --wait blocks until every Helm-tracked resource is actually gone
  # (not just accepted for deletion) - without it, Deployments/
  # StatefulSet pods, the Job, and its ServiceAccount are still
  # mid-termination when the namespace-inventory check below runs,
  # which would otherwise misreport them as unexpected leftovers.
  phelm uninstall "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE" --wait --timeout 5m
  echo "OK: release uninstalled (CRDs retained by chart design)"

  # The chart's redisSecretInit Job/Role/RoleBinding/ServiceAccount
  # carry only "helm.sh/hook-delete-policy: before-hook-creation"
  # (verified by inspecting templates/redis-secret-init/*.yaml in the
  # pinned chart) - that policy deletes them right before the NEXT
  # install's hook runs, never on `helm uninstall`. The Job also has its
  # own ttlSecondsAfterFinished, but that races the immediately-following
  # inventory check below, so this bootstrap removes exactly these four
  # named, hook-scoped objects it knows the chart leaves behind -
  # deleting the Job explicitly (rather than waiting on its TTL) also
  # cascades to its own Pod via the Job's ownerReference.
  hook_name="${ARGOCD_RELEASE_NAME}-redis-secret-init"
  for hook_res in "job.batch/${hook_name}" "role.rbac.authorization.k8s.io/${hook_name}" \
                  "rolebinding.rbac.authorization.k8s.io/${hook_name}" "serviceaccount/${hook_name}"; do
    if pkubectl -n "$ARGOCD_NAMESPACE" get "$hook_res" >/dev/null 2>&1; then
      pkubectl -n "$ARGOCD_NAMESPACE" delete "$hook_res" --wait
      echo "OK: removed orphaned hook object $hook_res (chart hook-delete-policy does not cover uninstall)"
    fi
  done
  # Belt-and-suspenders: the Job's own Pod may still be mid-GC-cascade
  # immediately after the Job delete above; remove any leftover directly
  # by its Kubernetes-assigned job-name label rather than racing the GC.
  pkubectl -n "$ARGOCD_NAMESPACE" delete pod -l "job-name=${hook_name}" --ignore-not-found --wait >/dev/null 2>&1 || true
else
  echo "OK: release '$ARGOCD_RELEASE_NAME' not installed - nothing to uninstall"
fi

if ! pkubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "OK: namespace '$ARGOCD_NAMESPACE' does not exist - nothing to clean up"
  exit 0
fi

# jsonpath treats "." as a path separator, so a literal "." inside the
# label key itself must be escaped ("\.") or the lookup silently resolves
# to nothing instead of the real value.
escaped_owner_key="$(printf '%s' "$ARGOCD_NS_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
owner_label="$(pkubectl get namespace "$ARGOCD_NAMESPACE" \
  -o jsonpath="{.metadata.labels.${escaped_owner_key}}" 2>/dev/null || true)"

if [ "$owner_label" != "$ARGOCD_NS_OWNER_LABEL_VALUE" ]; then
  echo "NOTE: namespace '$ARGOCD_NAMESPACE' is not owned by this bootstrap (owner label: '${owner_label:-<none>}') - left in place"
  exit 0
fi

if inventory_namespace_contents "$ARGOCD_NAMESPACE"; then
  pkubectl delete namespace "$ARGOCD_NAMESPACE"
  echo "OK: namespace '$ARGOCD_NAMESPACE' deleted (owned by this bootstrap, inventory clean)"
else
  echo "FAIL: refusing to delete namespace '$ARGOCD_NAMESPACE' - unexpected contents remain" >&2
  exit 1
fi

echo "argocd-uninstall: OK"
