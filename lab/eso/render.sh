#!/bin/sh
# Fully offline Helm render of the pinned External Secrets Operator
# chart, once per logical unit (the decoupled CRD set, the staging
# scoped release, the production scoped release), plus the full
# collision/ownership proof required before any of this is ever
# applied to a cluster: every rendered image is digest-pinned, no
# wildcard RBAC exists anywhere, the 25 CRDs never appear in either
# scoped release's own render, no (apiVersion, kind, namespace, name)
# tuple is rendered by both scoped releases, and the webhook/cert-
# controller singleton components render from exactly one release.
# Never touches the cluster, never downloads anything. Backs
# `make eso-render`.
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
require_helm
require_eso_chart

workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

fail=0

# --- render the three logical units ---
echo "eso-render: rendering the CRD source (all 25 CRD-creation flags enabled) ..."
if ! eso_render_crds_source "$workdir/crds-source.yaml" 2>"$workdir/crds.err"; then
  echo "FAIL: CRD source render failed" >&2
  cat "$workdir/crds.err" >&2
  exit 1
fi
eso_extract_crds "$workdir/crds-source.yaml" > "$workdir/crds-only.yaml"

echo "eso-render: rendering staging (scopedNamespace=staging, webhook/cert-controller owner) ..."
eso_write_values "staging" "true" "true" "$workdir/values-staging.yaml"
if ! phelm template eso-staging "$ESO_CHART_TGZ" -f "$workdir/values-staging.yaml" \
      --namespace eso-staging > "$workdir/render-staging.yaml" 2>"$workdir/staging.err"; then
  echo "FAIL: staging render failed" >&2
  cat "$workdir/staging.err" >&2
  exit 1
fi

echo "eso-render: rendering production (scopedNamespace=production, no webhook/cert-controller) ..."
eso_write_values "production" "false" "false" "$workdir/values-production.yaml"
if ! phelm template eso-production "$ESO_CHART_TGZ" -f "$workdir/values-production.yaml" \
      --namespace eso-production > "$workdir/render-production.yaml" 2>"$workdir/production.err"; then
  echo "FAIL: production render failed" >&2
  cat "$workdir/production.err" >&2
  exit 1
fi
echo "OK: all three renders succeeded"

# --- inventory: apiVersion<TAB>kind<TAB>namespace<TAB>name, one line per
# rendered document, built with a POSIX-portable YAML multi-document
# splitter (no YAML library dependency - matches this project's
# existing rendered-kind-filtering idiom). ---
inventory() {
  infile="$1"; outfile="$2"
  awk '
    function flush() {
      if (kind != "") {
        ns = (namespace == "") ? "-" : namespace
        print apiv "\t" kind "\t" ns "\t" name
      }
      apiv = ""; kind = ""; namespace = ""; name = ""; in_meta = 0
    }
    /^---[[:space:]]*$/ { flush(); next }
    /^apiVersion:[[:space:]]/ { sub(/^apiVersion:[[:space:]]*/, ""); apiv = $0; next }
    /^kind:[[:space:]]/ { sub(/^kind:[[:space:]]*/, ""); kind = $0; next }
    /^metadata:[[:space:]]*$/ { in_meta = 1; next }
    /^[a-zA-Z]/ { in_meta = 0 }
    in_meta && /^[[:space:]]+name:[[:space:]]/ && name == "" { sub(/^[[:space:]]+name:[[:space:]]*/, ""); gsub(/"/, ""); name = $0; next }
    in_meta && /^[[:space:]]+namespace:[[:space:]]/ && namespace == "" { sub(/^[[:space:]]+namespace:[[:space:]]*/, ""); gsub(/"/, ""); namespace = $0; next }
    END { flush() }
  ' "$infile" | grep -v '^\t\t\t$' | sort -u > "$outfile"
}

inventory "$workdir/render-staging.yaml" "$workdir/inv-staging.tsv"
inventory "$workdir/render-production.yaml" "$workdir/inv-production.tsv"

# --- 1/2. CRDs installed exactly once, never rendered by either scoped release ---
crd_count="$(grep -c '^kind: CustomResourceDefinition$' "$workdir/crds-only.yaml" || true)"
if [ "$crd_count" -ne 25 ]; then
  echo "FAIL: expected exactly 25 CRDs, got $crd_count" >&2
  fail=1
else
  echo "OK: exactly 25 CRDs rendered by the decoupled CRD unit"
fi
if grep -q "CustomResourceDefinition" "$workdir/inv-staging.tsv" "$workdir/inv-production.tsv"; then
  echo "FAIL: a scoped release renders a CustomResourceDefinition - CRD ownership is not decoupled" >&2
  fail=1
else
  echo "OK: neither scoped release renders or adopts any CRD"
fi

# --- 4. no namespaced/cluster-scoped resource collision between the two
# scoped releases (identical apiVersion+kind+namespace+name tuple) ---
collisions="$(comm -12 "$workdir/inv-staging.tsv" "$workdir/inv-production.tsv" || true)"
if [ -n "$collisions" ]; then
  echo "FAIL: staging and production releases render colliding resources:" >&2
  printf '%s\n' "$collisions" >&2
  fail=1
else
  echo "OK: no (apiVersion, kind, namespace, name) collision between staging and production"
fi

# --- 5/6. webhook and cert-controller exist at most once in the
# complete set (both are cluster-wide singletons: the
# ValidatingWebhookConfiguration names are fixed, non-release-qualified
# strings, and cert-controller manages that same cluster-wide webhook) ---
combined="$workdir/inv-combined.tsv"
cat "$workdir/inv-staging.tsv" "$workdir/inv-production.tsv" > "$combined"
webhook_cfg_count="$(grep -c 'ValidatingWebhookConfiguration' "$combined" || true)"
cert_deploy_count="$(awk -F'\t' '$2=="Deployment" && $4 ~ /cert-controller$/' "$combined" | wc -l | tr -d ' ')"
webhook_deploy_count="$(awk -F'\t' '$2=="Deployment" && $4 ~ /webhook$/' "$combined" | wc -l | tr -d ' ')"
if [ "$webhook_cfg_count" -ne 2 ]; then
  echo "FAIL: expected exactly 2 ValidatingWebhookConfiguration objects (externalsecret-validate, secretstore-validate), got $webhook_cfg_count" >&2
  fail=1
fi
if [ "$cert_deploy_count" -ne 1 ]; then
  echo "FAIL: expected exactly 1 cert-controller Deployment across the complete set, got $cert_deploy_count" >&2
  fail=1
fi
if [ "$webhook_deploy_count" -ne 1 ]; then
  echo "FAIL: expected exactly 1 webhook Deployment across the complete set, got $webhook_deploy_count" >&2
  fail=1
fi
[ "$webhook_cfg_count" -eq 2 ] && [ "$cert_deploy_count" -eq 1 ] && [ "$webhook_deploy_count" -eq 1 ] && \
  echo "OK: webhook and cert-controller each exist exactly once across the complete set (owned by eso-staging)"

# --- 9/10/11: each controller's own Role is scoped to exactly its own
# namespace, and no wildcard verb/resource/apiGroup exists anywhere. ---
if ! awk -F'\t' '$2=="Role" && $3=="staging" && $4=="eso-staging-external-secrets-controller"' "$workdir/inv-staging.tsv" | grep -q .; then
  echo "FAIL: staging controller Role not found scoped to namespace 'staging'" >&2
  fail=1
fi
if ! awk -F'\t' '$2=="Role" && $3=="production" && $4=="eso-production-external-secrets-controller"' "$workdir/inv-production.tsv" | grep -q .; then
  echo "FAIL: production controller Role not found scoped to namespace 'production'" >&2
  fail=1
fi
if awk -F'\t' '$2=="ClusterRole" && $4 ~ /-external-secrets-controller$/' "$combined" | grep -q .; then
  echo "FAIL: the main controller's Role rendered as a ClusterRole - scopedRBAC did not take effect" >&2
  fail=1
fi
echo "OK: each controller's Role is scoped to exactly its own namespace; no controller ClusterRole exists"

# Structural (field-aware) scan, not a blind grep for the substring
# '"*"' - catches unquoted block items, single-line inline/flow lists,
# and multi-line inline/flow lists, and only ever flags a value that is
# exactly "*" in one of apiGroups/resources/verbs/resourceNames/
# nonResourceURLs (see eso_check_no_rbac_wildcards in scripts/eso/_lib.sh).
wildcard_fail=0
for label in staging production; do
  hits="$(eso_check_no_rbac_wildcards "$workdir/render-${label}.yaml")" || wildcard_fail=1
  if [ -n "$hits" ]; then
    echo "FAIL: structural RBAC wildcard scan found violation(s) in $label:" >&2
    printf '%s\n' "$hits" >&2
  fi
done
if [ "$wildcard_fail" -ne 0 ]; then
  fail=1
else
  echo "OK: structural scan of apiGroups/resources/verbs/resourceNames/nonResourceURLs found no wildcard in either scoped release"
fi

# --- every rendered image is digest-pinned, never a mutable tag alone ---
for f in "$workdir/render-staging.yaml" "$workdir/render-production.yaml"; do
  if grep -E '^[[:space:]]*image:[[:space:]]' "$f" | grep -v '@sha256:' >/dev/null 2>&1; then
    echo "FAIL: $f contains a non-digest-pinned image reference" >&2
    fail=1
  fi
done
image_lines="$(grep -E '^[[:space:]]*image:[[:space:]]' "$workdir/render-staging.yaml" "$workdir/render-production.yaml" | sed -E 's/^.*image:[[:space:]]*//' | sort -u)"
[ "$fail" -eq 0 ] && echo "OK: every rendered image is digest-pinned:" && printf '%s\n' "$image_lines" | sed 's/^/      /'

if [ "$fail" -ne 0 ]; then
  echo "eso-render: FAILED"
  exit 1
fi
echo "eso-render: OK"
