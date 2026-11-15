#!/bin/sh
# Fail-closed, idempotent install of ONLY the 25 External Secrets
# Operator CRDs - no Helm release, no controller, no webhook. Backs
# `make eso-crds-install`, and is step 1 of lab/eso/install.sh.
#
# Why a separate entry point (R-13, fresh-cluster ordering): on
# lab-lite, Argo CD cannot sync charts/standard-workload (it renders a
# SecretStore and an ExternalSecret) until these CRDs exist, while the
# scoped ESO releases need the dev/uat/prod namespaces that Argo CD's
# first sync creates. Applying the CRDs alone before
# `make gitops-bootstrap` breaks that cycle: Argo CD syncs and creates
# the namespaces, and `make eso-install` then installs the releases.
# With no release installed there is no admission webhook yet, so the
# first sync never races a webhook that is not answering.
#
# The CRDs are applied with kubectl server-side apply under a stable,
# project-specific field manager, never by a Helm release, so no
# controller uninstall can ever delete them (lab/eso/uninstall.sh never
# touches them either).
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

# CRDs: applied once, owned by no Helm release, never re-applied
# if already present and correct (kubectl apply is itself idempotent;
# this additionally verifies the count before touching anything). ---
echo "eso-crds-install: rendering the 25 pinned CRDs from the chart ..."
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
echo "eso-crds-install: CRD apply preflight (dry-run=server, field-manager=$ESO_CRD_FIELD_MANAGER) ..."
if ! pkubectl apply --server-side --field-manager="$ESO_CRD_FIELD_MANAGER" --dry-run=server \
      -f "$workdir/crds-only.yaml" >"$workdir/crd-preflight.out" 2>&1; then
  echo "FAIL: CRD apply preflight detected a field-ownership conflict (or other server-side-apply rejection) - refusing to install; no CRD was modified, deleted, recreated, or force-adopted" >&2
  cat "$workdir/crd-preflight.out" >&2
  exit 1
fi
echo "OK: CRD apply preflight passed - no field-ownership conflict"

echo "eso-crds-install: applying the 25 CRDs (kubectl apply --server-side, field-manager=$ESO_CRD_FIELD_MANAGER, never a Helm release) ..."
pkubectl apply --server-side --field-manager="$ESO_CRD_FIELD_MANAGER" -f "$workdir/crds-only.yaml"

echo "eso-crds-install: waiting for all 25 CRDs to report Established ..."
while IFS= read -r crd; do
  [ -z "$crd" ] && continue
  pkubectl wait --for=condition=Established "customresourcedefinition/${crd}" --timeout=60s >/dev/null
done <<EOF
$(eso_crd_names)
EOF
echo "OK: 25 CRDs applied and Established"
echo "eso-crds-install: OK"
