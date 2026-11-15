#!/bin/sh
# Fully offline Helm render of the pinned External Secrets Operator
# chart, once per logical unit (the decoupled CRD set and each of the
# three scoped releases - dev, uat, prod), plus the full
# collision/ownership proof required before any of this is ever
# applied to a cluster: every rendered image is digest-pinned, no
# wildcard RBAC exists anywhere, the 25 CRDs never appear in any
# scoped release's own render, no (apiVersion, kind, namespace, name)
# tuple is rendered by two scoped releases, and the webhook/cert-
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

while IFS='|' read -r env_name ns release webhook_create cert_create; do
  [ -z "$env_name" ] && continue
  echo "eso-render: rendering $env_name (scopedNamespace=$env_name, webhook/cert-controller=$webhook_create) ..."
  eso_write_values "$env_name" "$webhook_create" "$cert_create" "$workdir/values-${env_name}.yaml"
  if ! phelm template "$release" "$ESO_CHART_TGZ" -f "$workdir/values-${env_name}.yaml" \
        --namespace "$ns" > "$workdir/render-${env_name}.yaml" 2>"$workdir/${env_name}.err"; then
    echo "FAIL: $env_name render failed" >&2
    cat "$workdir/${env_name}.err" >&2
    exit 1
  fi
done <<EOF
$(eso_environments)
EOF
eso_env_names="$(eso_environments | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
echo "OK: CRD unit and every scoped release ($eso_env_names) rendered"

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

for env_name in $eso_env_names; do
  inventory "$workdir/render-${env_name}.yaml" "$workdir/inv-${env_name}.tsv"
done

# --- 1/2. CRDs installed exactly once, never rendered by any scoped release ---
crd_count="$(grep -c '^kind: CustomResourceDefinition$' "$workdir/crds-only.yaml" || true)"
if [ "$crd_count" -ne 25 ]; then
  echo "FAIL: expected exactly 25 CRDs, got $crd_count" >&2
  fail=1
else
  echo "OK: exactly 25 CRDs rendered by the decoupled CRD unit"
fi
crd_in_release=0
for env_name in $eso_env_names; do
  grep -q "CustomResourceDefinition" "$workdir/inv-${env_name}.tsv" && crd_in_release=1
done
if [ "$crd_in_release" -ne 0 ]; then
  echo "FAIL: a scoped release renders a CustomResourceDefinition - CRD ownership is not decoupled" >&2
  fail=1
else
  echo "OK: no scoped release renders or adopts any CRD"
fi

# --- 4. no namespaced/cluster-scoped resource collision between any two
# scoped releases (identical apiVersion+kind+namespace+name tuple),
# checked pairwise ---
collision_fail=0
for a_env in $eso_env_names; do
  for b_env in $eso_env_names; do
    [ "$a_env" \< "$b_env" ] || continue
    collisions="$(comm -12 "$workdir/inv-${a_env}.tsv" "$workdir/inv-${b_env}.tsv" || true)"
    if [ -n "$collisions" ]; then
      echo "FAIL: $a_env and $b_env releases render colliding resources:" >&2
      printf '%s\n' "$collisions" >&2
      collision_fail=1
    fi
  done
done
if [ "$collision_fail" -ne 0 ]; then
  fail=1
else
  echo "OK: no (apiVersion, kind, namespace, name) collision between any two of $eso_env_names"
fi

# --- 5/6. webhook and cert-controller exist at most once in the
# complete set (both are cluster-wide singletons: the
# ValidatingWebhookConfiguration names are fixed, non-release-qualified
# strings, and cert-controller manages that same cluster-wide webhook) ---
combined="$workdir/inv-combined.tsv"
: > "$combined"
for env_name in $eso_env_names; do
  cat "$workdir/inv-${env_name}.tsv" >> "$combined"
done
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
  echo "OK: webhook and cert-controller each exist exactly once across the complete set (owned by $ESO_SINGLETON_OWNER_RELEASE)"

# --- 9/10/11: each controller's own Role is scoped to exactly its own
# namespace, and no wildcard verb/resource/apiGroup exists anywhere. ---
for env_name in $eso_env_names; do
  if ! awk -F'\t' -v e="$env_name" '$2=="Role" && $3==e && $4==("eso-" e "-external-secrets-controller")' "$workdir/inv-${env_name}.tsv" | grep -q .; then
    echo "FAIL: $env_name controller Role not found scoped to namespace '$env_name'" >&2
    fail=1
  fi
done
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
for label in $eso_env_names; do
  hits="$(eso_check_no_rbac_wildcards "$workdir/render-${label}.yaml")" || wildcard_fail=1
  if [ -n "$hits" ]; then
    echo "FAIL: structural RBAC wildcard scan found violation(s) in $label:" >&2
    printf '%s\n' "$hits" >&2
  fi
done
if [ "$wildcard_fail" -ne 0 ]; then
  fail=1
else
  echo "OK: structural scan of apiGroups/resources/verbs/resourceNames/nonResourceURLs found no wildcard in any scoped release"
fi

# --- every rendered image is digest-pinned, never a mutable tag alone ---
for env_name in $eso_env_names; do
  f="$workdir/render-${env_name}.yaml"
  if grep -E '^[[:space:]]*image:[[:space:]]' "$f" | grep -v '@sha256:' >/dev/null 2>&1; then
    echo "FAIL: $f contains a non-digest-pinned image reference" >&2
    fail=1
  fi
done
image_lines="$(for env_name in $eso_env_names; do grep -E '^[[:space:]]*image:[[:space:]]' "$workdir/render-${env_name}.yaml"; done | sed -E 's/^.*image:[[:space:]]*//' | sort -u)"
[ "$fail" -eq 0 ] && echo "OK: every rendered image is digest-pinned:" && printf '%s\n' "$image_lines" | sed 's/^/      /'

if [ "$fail" -ne 0 ]; then
  echo "eso-render: FAILED"
  exit 1
fi
echo "eso-render: OK"
