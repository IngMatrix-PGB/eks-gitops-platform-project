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
#   2. Two scoped ("scopedRBAC") Helm releases, `eso-staging` and
#      `eso-production`, each watching exactly one workload namespace.
#      Only `eso-staging` runs the webhook/cert-controller - both are
#      cluster-wide singletons by construction (see scripts/eso/_lib.sh).
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

# --- 1. CRDs: applied once, owned by no Helm release, never re-applied
# if already present and correct (kubectl apply is itself idempotent;
# this additionally verifies the count before touching anything). ---
echo "eso-install: rendering the 25 pinned CRDs from the chart ..."
eso_render_crds_source "$workdir/crds-source.yaml"
eso_extract_crds "$workdir/crds-source.yaml" > "$workdir/crds-only.yaml"
rendered_crd_count="$(grep -c '^kind: CustomResourceDefinition$' "$workdir/crds-only.yaml" || true)"
if [ "$rendered_crd_count" -ne 25 ]; then
  echo "FAIL: expected to render exactly 25 CRDs, got $rendered_crd_count - refusing to apply" >&2
  exit 1
fi

# --server-side, not client-side apply: at least two of these CRDs
# (secretstores, clustersecretstores) have an OpenAPI schema large
# enough that client-side apply's kubectl.kubernetes.io/last-applied-
# configuration annotation exceeds the API server's 256KiB annotation
# limit ("metadata.annotations: Too long") - a real, empirically-hit
# failure, not a hypothetical. Server-side apply never writes that
# annotation at all, so the size limit does not apply.
#
# Never --force-conflicts. A field-ownership conflict (some other field
# manager already owns a field this apply would also set) must stop
# the install with the CRD completely untouched - never silently
# force-adopted, overwritten, deleted, or recreated. Two-phase,
# fail-closed:
#   1. --dry-run=server detects a conflict (or any other server-side-
#      apply rejection) with zero mutation - proven empirically: a
#      failed dry-run leaves every field's existing owner exactly as
#      it was.
#   2. Only if the dry-run succeeds does the real apply run, under the
#      same stable, project-specific field manager - so a legitimate
#      re-apply from this same tool is never its own "conflict" (a
#      manager cannot conflict with its own prior claims), while a
#      genuine foreign-manager conflict still stops this script via
#      `set -eu`, without ever retrying with --force-conflicts.
echo "eso-install: CRD apply preflight (dry-run=server, field-manager=$ESO_CRD_FIELD_MANAGER) ..."
if ! pkubectl apply --server-side --field-manager="$ESO_CRD_FIELD_MANAGER" --dry-run=server \
      -f "$workdir/crds-only.yaml" >"$workdir/crd-preflight.out" 2>&1; then
  echo "FAIL: CRD apply preflight detected a field-ownership conflict (or other server-side-apply rejection) - refusing to install; no CRD was modified, deleted, recreated, or force-adopted" >&2
  cat "$workdir/crd-preflight.out" >&2
  exit 1
fi
echo "OK: CRD apply preflight passed - no field-ownership conflict"

echo "eso-install: applying the 25 CRDs (kubectl apply --server-side, field-manager=$ESO_CRD_FIELD_MANAGER, never a Helm release) ..."
pkubectl apply --server-side --field-manager="$ESO_CRD_FIELD_MANAGER" -f "$workdir/crds-only.yaml"

echo "eso-install: waiting for all 25 CRDs to report Established ..."
while IFS= read -r crd; do
  [ -z "$crd" ] && continue
  pkubectl wait --for=condition=Established "customresourcedefinition/${crd}" --timeout=60s >/dev/null
done <<EOF
$(eso_crd_names)
EOF
echo "OK: 25 CRDs applied and Established"

# --- 2. two scoped controller releases ---
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
