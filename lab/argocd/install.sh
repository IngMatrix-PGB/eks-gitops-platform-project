#!/bin/sh
# Fail-closed, idempotent Argo CD installer.
#   absent      -> installs
#   exact match -> true no-op (never calls `helm upgrade --install`)
#   any drift   -> fails closed, no automatic reconciliation
# Requires the project kind cluster to already exist and match its
# expected identity, the pinned Helm binary, and the pinned chart
# (already fetched via `make argocd-chart-fetch`). Backs `make argocd-install`.
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
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity - run 'make lab-create' first" >&2
  exit 1
fi
require_helm
require_argocd_chart

if check_argocd_install_identity; then
  echo "OK: argocd release already installed and matches the pinned chart/values/manifest exactly - no-op"
  exit 0
fi

case "$ARGOCD_INSTALL_CASE" in
  absent)
    echo "argocd-install: release absent - installing"
    ;;
  chart_drift)
    echo "FAIL: installed release chart/app-version does not match the pinned chart - refusing to reconcile automatically" >&2
    exit 1
    ;;
  bad_status)
    echo "FAIL: installed release status is not 'deployed' - refusing to reconcile automatically" >&2
    exit 1
    ;;
  values_drift)
    echo "FAIL: installed release values fingerprint does not match ${ARGOCD_VALUES_FILE} - refusing to reconcile automatically" >&2
    exit 1
    ;;
  manifest_drift)
    echo "FAIL: installed release's live manifest does not match the offline-rendered desired manifest - refusing to reconcile automatically" >&2
    exit 1
    ;;
  *)
    echo "FAIL: unknown install identity case '$ARGOCD_INSTALL_CASE'" >&2
    exit 1
    ;;
esac

if ! pkubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  pkubectl create namespace "$ARGOCD_NAMESPACE"
  pkubectl label namespace "$ARGOCD_NAMESPACE" "${ARGOCD_NS_OWNER_LABEL_KEY}=${ARGOCD_NS_OWNER_LABEL_VALUE}" --overwrite
  echo "OK: namespace '$ARGOCD_NAMESPACE' created and labeled"
else
  echo "OK: namespace '$ARGOCD_NAMESPACE' already exists"
fi

values_sha="$(argocd_values_fingerprint)"
echo "argocd-install: installing release '$ARGOCD_RELEASE_NAME' from $ARGOCD_CHART_TGZ ..."
phelm upgrade --install "$ARGOCD_RELEASE_NAME" "$ARGOCD_CHART_TGZ" \
  --namespace "$ARGOCD_NAMESPACE" \
  -f "$ARGOCD_VALUES_FILE" \
  --description "values-sha256:${values_sha}" \
  --wait --timeout 5m

echo "OK: argocd installed"

if ! compare_desired_vs_live_manifest; then
  echo "FAIL: post-install manifest comparison did not match - installed state diverges from the offline render" >&2
  exit 1
fi

echo "argocd-install: OK"
