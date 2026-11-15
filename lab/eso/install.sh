#!/bin/sh
# Fail-closed, idempotent External Secrets Operator installer.
#
# Two-part install, deliberately never combined into one Helm release:
#   1. The 25 CRDs are applied via `kubectl apply` directly (never a
#      Helm release) - decoupling their lifecycle entirely from either
#      environment's controller release, so uninstalling a controller
#      release can never delete them (this chart's CRDs are plain
#      templates with no retention annotation; a Helm release that
#      owned them would delete them on `helm uninstall`).
#   2. Three scoped ("scopedRBAC") Helm releases, `eso-uat`, `eso-dev`
#      and `eso-prod`, each watching exactly one workload namespace,
#      installed in that order (singleton owner first). Only `eso-uat`
#      runs the webhook/cert-controller - both are cluster-wide
#      singletons by construction (see scripts/eso/_lib.sh).
#
# Requires the project kind cluster to already exist and match its
# expected identity, the pinned Helm binary, and the pinned chart
# (already fetched via `make eso-chart-fetch`). Backs `make eso-install`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/eso/_lib.sh
. scripts/eso/_lib.sh
eso_require_workload_cluster

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity - run 'make lab-create' first" >&2
  exit 1
fi
require_helm
require_eso_chart

workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

# --- 0. preflight, zero mutation: every workload namespace a scoped
# release targets must already exist. On lab-lite Argo CD creates
# dev/uat/prod on its first sync (`make eso-crds-install`, then
# `make gitops-bootstrap`); on a lab-multicluster spoke
# `make mc-spoke-register` creates it. Checked before anything is
# applied, so a missing namespace can never leave a half-installed,
# "failed" Helm release behind (which the reconcile check below would
# then refuse to touch). ---
missing_ns=""
while IFS='|' read -r env_name ns release webhook_create cert_create; do
  [ -z "$env_name" ] && continue
  if ! pkubectl get namespace "$env_name" >/dev/null 2>&1; then
    missing_ns="${missing_ns} ${env_name}"
  fi
done <<EOF
$(eso_environments)
EOF
if [ -n "$missing_ns" ]; then
  echo "FAIL: workload namespace(s)${missing_ns} absent - the scoped ESO releases need them; nothing was applied" >&2
  case "${LAB_CLUSTER:-lab-lite}" in
    lab-lite) echo "      run 'make eso-crds-install', then 'make gitops-bootstrap', wait for dev/uat/prod, then 'make eso-install' again (R-13)" >&2 ;;
    *) echo "      run 'make mc-spoke-register SPOKE=${LAB_CLUSTER}' first" >&2 ;;
  esac
  exit 1
fi
echo "OK: preflight - every scoped workload namespace exists"

# --- 1. CRDs (lab/eso/install-crds.sh, also `make eso-crds-install`):
# 25 CRDs applied via kubectl server-side apply, owned by no Helm
# release. ---
sh lab/eso/install-crds.sh

# --- 2. three scoped controller releases (eso_environments order) ---
while IFS='|' read -r env_name ns release webhook_create cert_create; do
  [ -z "$env_name" ] && continue

  if ! pkubectl get namespace "$ns" >/dev/null 2>&1; then
    pkubectl create namespace "$ns"
    pkubectl label namespace "$ns" "${ESO_NS_OWNER_LABEL_KEY}=${ESO_NS_OWNER_LABEL_VALUE}" --overwrite
    echo "OK: namespace '$ns' created and labeled"
  else
    echo "OK: namespace '$ns' already exists"
  fi

  values_file="$workdir/values-${env_name}.yaml"
  eso_write_values "$env_name" "$webhook_create" "$cert_create" "$values_file"
  values_sha="$(shasum -a 256 "$values_file" | awk '{print $1}')"

  if eso_release_exists "$ns" "$release"; then
    list_json="$(phelm list -n "$ns" -o json 2>/dev/null)"
    chart_string="$(printf '%s' "$list_json" | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')"
    expected_chart="external-secrets-${ESO_CHART_VERSION}"
    status_json="$(phelm status "$release" -n "$ns" -o json 2>/dev/null)"
    status_prefix="$(printf '%s' "$status_json" | sed 's/,"notes":.*//')"
    rel_status="$(printf '%s' "$status_prefix" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    description="$(printf '%s' "$status_prefix" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"
    expected_description="values-sha256:${values_sha}"

    if [ "$chart_string" != "$expected_chart" ]; then
      echo "FAIL: release '$release' chart '$chart_string' does not match pinned '$expected_chart' - refusing to reconcile automatically" >&2
      exit 1
    fi
    if [ "$rel_status" != "deployed" ]; then
      echo "FAIL: release '$release' status '$rel_status' is not 'deployed' - refusing to reconcile automatically" >&2
      exit 1
    fi
    if [ "$description" = "$expected_description" ]; then
      echo "OK: release '$release' already installed and matches the pinned chart/values exactly - no-op"
      continue
    fi
    echo "eso-install: release '$release' values changed (sha256 $values_sha) - upgrading"
  else
    echo "eso-install: release '$release' absent - installing"
  fi

  phelm upgrade --install "$release" "$ESO_CHART_TGZ" \
    --namespace "$ns" \
    -f "$values_file" \
    --description "values-sha256:${values_sha}" \
    --wait --timeout 5m

  echo "OK: release '$release' installed in namespace '$ns' (scopedNamespace=$env_name)"
done <<EOF
$(eso_environments)
EOF

echo "eso-install: OK"
