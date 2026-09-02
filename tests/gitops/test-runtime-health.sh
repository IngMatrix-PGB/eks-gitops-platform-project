#!/bin/sh
# Read-only runtime health checks against an already-bootstrapped Phase
# 2.3 GitOps state: root Application, AppProject, ApplicationSet, both
# generated Applications, both namespaces, and both ConfigMaps. Never
# mutates anything. Backs `make gitops-test` only.
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

fail=0

if ! gitops_root_app_exists; then
  echo "FAIL: root Application '$GITOPS_ROOT_APP_NAME' is absent - run 'make gitops-bootstrap' first" >&2
  exit 1
fi
read -r rsync rhealth <<EOF
$(gitops_app_sync_health "$GITOPS_ROOT_APP_NAME")
EOF
if [ "$rsync" = "Synced" ] && [ "$rhealth" = "Healthy" ]; then
  echo "OK: root Application Synced/Healthy"
else
  echo "FAIL: root Application sync=$rsync health=$rhealth (expected Synced/Healthy)" >&2
  fail=1
fi

if gitops_appproject_exists; then
  echo "OK: AppProject '$GITOPS_PROJECT_NAME' present"
else
  echo "FAIL: AppProject '$GITOPS_PROJECT_NAME' absent" >&2
  fail=1
fi

if gitops_appset_exists; then
  echo "OK: ApplicationSet '$GITOPS_APPSET_NAME' present"
else
  echo "FAIL: ApplicationSet '$GITOPS_APPSET_NAME' absent" >&2
  fail=1
fi

for app in $GITOPS_GENERATED_APPS; do
  if ! gitops_generated_app_exists "$app"; then
    echo "FAIL: generated Application '$app' absent" >&2
    fail=1
    continue
  fi
  read -r sync health <<EOF
$(gitops_app_sync_health "$app")
EOF
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    echo "OK: Application '$app' Synced/Healthy"
  else
    echo "FAIL: Application '$app' sync=$sync health=$health (expected Synced/Healthy)" >&2
    fail=1
  fi
done

for ns in staging production; do
  actual="$(pkubectl -n "$ns" get configmap platform-smoke -o jsonpath='{.data.environment}' 2>/dev/null || true)"
  if [ "$actual" = "$ns" ]; then
    echo "OK: namespace '$ns' configmap/platform-smoke data.environment='$actual'"
  else
    echo "FAIL: namespace '$ns' configmap/platform-smoke data.environment='${actual:-<absent>}', expected '$ns'" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "gitops-test: FAILED"
  exit 1
fi
echo "gitops-test: OK"
