#!/bin/sh
# Read-only runtime health checks against an already-installed Argo CD
# release: every expected workload has its desired replica count Ready,
# the argocd-server Service exists, and the release identity matches
# the pinned chart/values. Never mutates anything. Backs
# `make argocd-test-runtime-health` only.
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

if ! argocd_release_exists; then
  echo "FAIL: test-runtime-health: release '$ARGOCD_RELEASE_NAME' is not installed - run 'make argocd-install' first" >&2
  exit 1
fi

fail=0

echo "test-runtime-health: checking Deployments ..."
for dep in argocd-applicationset-controller argocd-repo-server argocd-server argocd-redis; do
  desired="$(pkubectl -n "$ARGOCD_NAMESPACE" get deployment "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || desired=""
  ready="$(pkubectl -n "$ARGOCD_NAMESPACE" get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || ready=""
  if [ -z "$desired" ]; then
    echo "FAIL: Deployment/$dep not found" >&2
    fail=1
    continue
  fi
  if [ "$ready" != "$desired" ]; then
    echo "FAIL: Deployment/$dep readyReplicas='$ready' != spec.replicas='$desired'" >&2
    fail=1
    continue
  fi
  echo "OK: Deployment/$dep ready ($ready/$desired)"
done

echo "test-runtime-health: checking StatefulSets ..."
for sts in argocd-application-controller; do
  desired="$(pkubectl -n "$ARGOCD_NAMESPACE" get statefulset "$sts" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || desired=""
  ready="$(pkubectl -n "$ARGOCD_NAMESPACE" get statefulset "$sts" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || ready=""
  if [ -z "$desired" ]; then
    echo "FAIL: StatefulSet/$sts not found" >&2
    fail=1
    continue
  fi
  if [ "$ready" != "$desired" ]; then
    echo "FAIL: StatefulSet/$sts readyReplicas='$ready' != spec.replicas='$desired'" >&2
    fail=1
    continue
  fi
  echo "OK: StatefulSet/$sts ready ($ready/$desired)"
done

echo "test-runtime-health: checking Service ..."
if pkubectl -n "$ARGOCD_NAMESPACE" get svc argocd-server >/dev/null 2>&1; then
  echo "OK: Service/argocd-server exists"
else
  echo "FAIL: Service/argocd-server not found" >&2
  fail=1
fi

echo "test-runtime-health: checking pods for CrashLoopBackOff/Error ..."
bad_pods="$(pkubectl -n "$ARGOCD_NAMESPACE" get pods --no-headers 2>/dev/null \
  | awk '$3 != "Running" && $3 != "Completed" {print}')"
if [ -n "$bad_pods" ]; then
  echo "FAIL: unhealthy pod(s) in namespace '$ARGOCD_NAMESPACE':" >&2
  printf '%s\n' "$bad_pods" >&2
  fail=1
else
  echo "OK: all pods Running or Completed"
fi

echo "test-runtime-health: checking release identity vs pinned chart/values ..."
if check_argocd_install_identity; then
  echo "OK: release identity matches the pinned chart/values/manifest exactly"
else
  echo "FAIL: release identity check returned case '$ARGOCD_INSTALL_CASE'" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-runtime-health: FAILED"
  exit 1
fi
echo "test-runtime-health: OK"
