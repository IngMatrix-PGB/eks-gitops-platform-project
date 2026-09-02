#!/bin/sh
# Deletes the root Application using normal foreground cascading
# behavior (its resources-finalizer.argocd.argoproj.io causes Argo CD
# to delete the AppProject/ApplicationSet/generated Applications/
# ConfigMaps it manages before the Application object itself
# disappears), then deletes the staging/production namespaces only if
# this bootstrap owns them and an exhaustive inventory shows nothing
# unexpected remains. Never force-removes a finalizer. Preserves Argo
# CD itself, its CRDs, the repository Secret, and the deploy key -
# none of those are touched here. Idempotent. Backs `make
# gitops-uninstall`.
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
# shellcheck source=../../scripts/gitops/_lib.sh
. scripts/gitops/_lib.sh

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

if gitops_root_app_exists; then
  echo "gitops-uninstall: deleting root Application '$GITOPS_ROOT_APP_NAME' (foreground cascade via finalizer) ..."
  # Observed empirically: the root's own finalizer deletes its two
  # rendered children (AppProject, ApplicationSet) without an ordering
  # guarantee between them. If the AppProject disappears first, the
  # ApplicationSet's already-generated Applications briefly fail to
  # resolve their project reference; the application-controller's next
  # resync (informer-cache-bound, observed up to ~2-3 minutes even on a
  # healthy chain) retries and completes the delete correctly on its
  # own - never a real deadlock, just slower than a short timeout
  # suggests. 300s comfortably covers that, without ever force-removing
  # a finalizer.
  pkubectl -n "$ARGOCD_NAMESPACE" delete application "$GITOPS_ROOT_APP_NAME" --wait --timeout=300s
  echo "OK: root Application deleted (cascade removed AppProject/ApplicationSet/generated Applications/ConfigMaps)"
else
  echo "OK: root Application '$GITOPS_ROOT_APP_NAME' already absent"
fi

fail=0
if gitops_appproject_exists; then
  echo "FAIL: AppProject '$GITOPS_PROJECT_NAME' still present after root Application deletion" >&2
  fail=1
fi
if gitops_appset_exists; then
  echo "FAIL: ApplicationSet '$GITOPS_APPSET_NAME' still present after root Application deletion" >&2
  fail=1
fi
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    echo "FAIL: generated Application '$app' still present after root Application deletion" >&2
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "gitops-uninstall: FAILED - refusing to touch namespaces while managed resources remain (never force-removing a finalizer)" >&2
  exit 1
fi
echo "OK: AppProject, ApplicationSet, and both generated Applications are gone"

for ns in staging production; do
  if ! pkubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "OK: namespace '$ns' does not exist - nothing to clean up"
    continue
  fi

  escaped_owner_key="$(printf '%s' "$GITOPS_NS_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
  owner_label="$(pkubectl get namespace "$ns" -o jsonpath="{.metadata.labels.${escaped_owner_key}}" 2>/dev/null || true)"

  if [ "$owner_label" != "$GITOPS_NS_OWNER_LABEL_VALUE" ]; then
    echo "NOTE: namespace '$ns' is not owned by this bootstrap (owner label: '${owner_label:-<none>}') - left in place" >&2
    echo "FAIL: cleanup would affect a namespace this bootstrap does not own - stopping" >&2
    exit 1
  fi

  if inventory_namespace_contents "$ns"; then
    pkubectl delete namespace "$ns"
    echo "OK: namespace '$ns' deleted (owned by this bootstrap, inventory clean)"
  else
    echo "FAIL: refusing to delete namespace '$ns' - unexpected contents remain" >&2
    exit 1
  fi
done

echo "gitops-uninstall: OK"
