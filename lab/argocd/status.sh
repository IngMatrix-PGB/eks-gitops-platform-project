#!/bin/sh
# Read-only Argo CD status report: Helm release identity, workload
# health, and CRD state. Never mutates anything. Backs `make argocd-status`.
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
  echo "argocd-status: release NOT INSTALLED"
  if detect_crd_state; then
    echo "CRD_STATE=$CRD_STATE"
  else
    echo "CRD_STATE=$CRD_STATE" >&2
  fi
  exit 0
fi

echo "--- helm list ---"
phelm list -n "$ARGOCD_NAMESPACE"

echo "--- helm status ---"
phelm status "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE"

echo "--- workloads ---"
pkubectl -n "$ARGOCD_NAMESPACE" get deployments,statefulsets,pods

echo "--- CRD state ---"
if detect_crd_state; then
  echo "CRD_STATE=$CRD_STATE"
else
  echo "CRD_STATE=$CRD_STATE" >&2
fi

echo "--- install identity vs pinned chart/values ---"
if check_argocd_install_identity; then
  echo "IDENTITY=match"
else
  echo "IDENTITY=$ARGOCD_INSTALL_CASE"
fi
