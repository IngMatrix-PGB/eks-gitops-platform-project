#!/bin/sh
# Read-only Phase 2.3 GitOps status report: root Application, AppProject,
# ApplicationSet, generated Applications, environment ConfigMaps. Never
# mutates anything. Backs `make gitops-status`.
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

echo "--- repository authentication (read-only check) ---"
GITOPS_CHECK_ONLY=1 sh lab/gitops/repo-setup.sh || true

echo "--- root Application ---"
if gitops_root_app_exists; then
  read -r rsync rhealth <<EOF
$(gitops_app_sync_health "$GITOPS_ROOT_APP_NAME")
EOF
  echo "NAME=$GITOPS_ROOT_APP_NAME SYNC=$rsync HEALTH=$rhealth"
else
  echo "root Application '$GITOPS_ROOT_APP_NAME': absent"
fi

echo "--- AppProject ---"
if gitops_appproject_exists; then
  pkubectl -n "$ARGOCD_NAMESPACE" get appproject "$GITOPS_PROJECT_NAME" -o jsonpath='name={.metadata.name} sourceRepos={.spec.sourceRepos} destinations={.spec.destinations}{"\n"}'
else
  echo "AppProject '$GITOPS_PROJECT_NAME': absent"
fi

echo "--- ApplicationSet ---"
if gitops_appset_exists; then
  pkubectl -n "$ARGOCD_NAMESPACE" get applicationset "$GITOPS_APPSET_NAME"
else
  echo "ApplicationSet '$GITOPS_APPSET_NAME': absent"
fi

echo "--- generated Applications ---"
for app in $GITOPS_GENERATED_APPS; do
  if gitops_generated_app_exists "$app"; then
    read -r sync health <<EOF
$(gitops_app_sync_health "$app")
EOF
    echo "NAME=$app SYNC=$sync HEALTH=$health"
  else
    echo "Application '$app': absent"
  fi
done

echo "--- environment ConfigMaps ---"
for ns in staging production; do
  if pkubectl -n "$ns" get configmap platform-smoke >/dev/null 2>&1; then
    pkubectl -n "$ns" get configmap platform-smoke -o jsonpath="namespace=${ns} data={.data}{\"\n\"}"
  else
    echo "namespace=${ns}: configmap/platform-smoke absent"
  fi
done
