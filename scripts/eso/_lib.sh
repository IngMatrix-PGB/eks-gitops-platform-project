#!/bin/sh
# Shared constants and helpers for lab/eso/*.sh, scripts/validate/check-
# eso-chart.sh, and tests/eso/*.sh. POSIX-compatible shell only - no
# bashisms. Sourced, never executed directly. Assumes the caller's
# working directory is the repository root, and that scripts/lab/_lib.sh
# (project cluster/kubeconfig constants, pkubectl) has already been
# sourced first.
#
# Architecture (see docs/adr/0010-external-secrets-operator-contract.md
# and .local/evidence/phase-2.6-external-secrets-plan.md for the full
# rationale): the External Secrets Operator's 25 CRDs are installed
# exactly once, decoupled from either environment's controller - never
# owned by a Helm release, so uninstalling a scoped controller release
# can never delete them (this chart renders CRDs as plain templates
# with no `helm.sh/resource-policy: keep` annotation, so a Helm release
# that owned them WOULD delete them on `helm uninstall`). Two scoped,
# namespace-restricted ("scopedRBAC") controller releases then each
# watch exactly one workload namespace (`staging`/`production`). Only
# ONE of the two releases runs the webhook and cert-controller
# components - both are cluster-wide singletons by construction (the
# webhook's `ValidatingWebhookConfiguration` objects have fixed,
# non-release-qualified names; cert-controller manages that same
# cluster-wide webhook's CA) - running them from both releases would
# collide, not merely duplicate. `eso-staging` is the arbitrary but
# fixed owner of both singletons.

ESO_CHART_VERSION="2.10.0"
ESO_CHART_APP_VERSION="v2.10.0"
# The chart is pinned to the `helm-chart-2.10.0` release tag, NOT the
# `v2.10.0` app tag - at the `v2.10.0` tag, deploy/charts/external-
# secrets/Chart.yaml still reads version "2.9.0"; the chart's own
# version bump to "2.10.0" is a separate, later release event tagged
# `helm-chart-2.10.0`. Verified directly against both tags before this
# pin was recorded - never assumed from the app version alone.
ESO_CHART_URL="https://github.com/external-secrets/external-secrets/releases/download/helm-chart-2.10.0/external-secrets-2.10.0.tgz"
ESO_CHART_SHA256="b96e948fff3674638b5d3f9e43886f3796e04739c4b4127929aed2ddac7d1418"
ESO_CHART_TGZ=".tools/charts/external-secrets-${ESO_CHART_VERSION}.tgz"

ESO_IMAGE_REPOSITORY="ghcr.io/external-secrets/external-secrets"
# Multi-arch index digest for tag v2.10.0 (linux/amd64 and linux/arm64
# both present in this index; resolved via the GHCR registry API, never
# guessed). This chart's own image-reference template
# (`external-secrets.image` in _helpers.tpl) unconditionally renders
# "<repository>:<tag>" with no native digest field - so the digest is
# carried inside the tag value itself, producing the fully valid
# `name:tag@digest` reference form (OCI/Docker reference grammar
# permits a tag and a digest together; the digest is what is actually
# resolved and pulled - the tag becomes informational only). This still
# satisfies "never a mutable tag alone": the bytes pulled are digest-
# determined regardless of what the tag portion says.
ESO_IMAGE_DIGEST="sha256:814117b0fd6d121b03e8ba3b6db1cecbe7449a354fc0fc9c4faf73a37aa221b1"
ESO_IMAGE_TAG="${ESO_CHART_APP_VERSION}@${ESO_IMAGE_DIGEST}"

ESO_NS_OWNER_LABEL_KEY="eks-gitops-lab-lite.local/owner"
ESO_NS_OWNER_LABEL_VALUE="eso-bootstrap"

# Stable, project-specific field manager for every CRD server-side
# apply this bootstrap ever performs. Never combined with
# --force-conflicts: a conflict against any OTHER field manager must
# stop the install with no mutation, not be forced through. Re-applying
# from this same manager is always conflict-free by definition (a
# manager never conflicts with its own prior claims), which is what
# makes ordinary idempotent re-installs work without force.
ESO_CRD_FIELD_MANAGER="eks-gitops-lab-lite-eso-bootstrap"

# eso-staging is the fixed, arbitrary owner of the cluster-wide
# webhook/cert-controller singletons (see the file header). This makes
# that dependency explicit and checkable in code, not just in comments:
# eso-production's admission validation (ExternalSecret/SecretStore)
# and CA management depend on eso-staging's webhook/cert-controller
# Deployments - removing eso-staging while eso-production still exists
# would silently break admission control for both environments.
ESO_SINGLETON_OWNER_ENV="staging"
ESO_SINGLETON_OWNER_NS="eso-staging"
ESO_SINGLETON_OWNER_RELEASE="eso-staging"
ESO_DEPENDENT_ENV="production"
ESO_DEPENDENT_NS="eso-production"
ESO_DEPENDENT_RELEASE="eso-production"

HELM_BIN=".tools/bin/helm"

require_eso_chart() {
  if [ ! -f "$ESO_CHART_TGZ" ]; then
    echo "FAIL: $ESO_CHART_TGZ not found - run 'make eso-chart-fetch' first" >&2
    exit 1
  fi
  actual_sha="$(shasum -a 256 "$ESO_CHART_TGZ" | awk '{print $1}')"
  if [ "$actual_sha" != "$ESO_CHART_SHA256" ]; then
    echo "FAIL: $ESO_CHART_TGZ does not match the pinned checksum - run 'make eso-chart-fetch' again" >&2
    exit 1
  fi
}

# require_helm/phelm: shared with scripts/argocd/_lib.sh (Phase 3.2.1
# consolidation - the two were byte-identical). HELM_BIN above must stay
# set before this source line.
# shellcheck source=../lib/helm.sh
. scripts/lib/helm.sh

# The 25 CRDs this chart's default values render - the single source of
# truth this project checks CRD presence/count against everywhere.
eso_crd_names() {
  cat <<'EOF'
acraccesstokens.generators.external-secrets.io
beyondtrustworkloadcredentialsdynamicsecrets.generators.external-secrets.io
cloudsmithaccesstokens.generators.external-secrets.io
clusterexternalsecrets.external-secrets.io
clustergenerators.generators.external-secrets.io
clusterpushsecrets.external-secrets.io
clustersecretstores.external-secrets.io
ecrauthorizationtokens.generators.external-secrets.io
externalsecrets.external-secrets.io
fakes.generators.external-secrets.io
gcraccesstokens.generators.external-secrets.io
generatorstates.generators.external-secrets.io
githubaccesstokens.generators.external-secrets.io
gitlabdeploytokens.generators.external-secrets.io
grafanas.generators.external-secrets.io
mfas.generators.external-secrets.io
passwords.generators.external-secrets.io
pushsecrets.external-secrets.io
quayaccesstokens.generators.external-secrets.io
secretstores.external-secrets.io
sshkeys.generators.external-secrets.io
stssessiontokens.generators.external-secrets.io
uuids.generators.external-secrets.io
vaultdynamicsecrets.generators.external-secrets.io
webhooks.generators.external-secrets.io
EOF
}

# Renders the chart with every CRD-creation flag enabled (all 25) and
# writes the FULL render to $1 - callers extract only the
# CustomResourceDefinition documents from it (see eso_extract_crds).
# Never applied directly; the full render also contains a throwaway
# controller/webhook/cert-controller set that is discarded.
eso_render_crds_source() {
  outfile="$1"
  phelm template eso-crds "$ESO_CHART_TGZ" --namespace kube-system \
    --set installCRDs=true \
    --set crds.createClusterExternalSecret=true \
    --set crds.createClusterSecretStore=true \
    --set crds.createSecretStore=true \
    --set crds.createClusterGenerator=true \
    --set crds.createClusterPushSecret=true \
    --set crds.createPushSecret=true \
    > "$outfile"
}

# Splits a multi-document `helm template` render on the `---` document
# separator and prints only documents whose first `kind:` line is
# CustomResourceDefinition. POSIX awk, no YAML library dependency -
# matches this project's existing rendered-kind-filtering idiom
# (scripts/validate/check-standard-workload-chart.sh).
eso_extract_crds() {
  infile="$1"
  awk '
    BEGIN { doc = ""; is_crd = 0; printed = 0 }
    /^---[[:space:]]*$/ {
      if (doc != "" && is_crd) {
        if (printed) { print "---" }
        printf "%s", doc
        printed = 1
      }
      doc = ""; is_crd = 0
      next
    }
    {
      doc = doc $0 "\n"
      if ($0 ~ /^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$/) { is_crd = 1 }
    }
    END {
      if (doc != "" && is_crd) {
        if (printed) { print "---" }
        printf "%s", doc
      }
    }
  ' "$infile"
}

# Writes the values file for one scoped controller release. $1=env name
# (staging|production) $2=webhook create (true|false) $3=cert-controller
# create (true|false) $4=output path. CRDs are always disabled here -
# they are never rendered or owned by either scoped release (see the
# file header). scopedRBAC converts every ClusterRole/ClusterRoleBinding
# the controller itself would otherwise need into a namespaced
# Role/RoleBinding restricted to $1 - verified empirically by rendering
# and inspecting the output, not assumed from the values.yaml comment
# alone (see the plan's collision-gate evidence).
eso_write_values() {
  env_name="$1"; webhook_create="$2"; cert_create="$3"; outfile="$4"
  cat > "$outfile" <<VALUESEOF
installCRDs: false
crds:
  createClusterExternalSecret: false
  createClusterSecretStore: false
  createSecretStore: false
  createClusterGenerator: false
  createClusterPushSecret: false
  createPushSecret: false
scopedRBAC: true
scopedNamespace: "${env_name}"
rbac:
  servicebindings:
    create: false
processClusterExternalSecret: false
processClusterPushSecret: false
processClusterStore: false
processClusterGenerator: false
processPushSecret: false
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits: { cpu: 200m, memory: 128Mi }
image:
  repository: ${ESO_IMAGE_REPOSITORY}
  tag: "${ESO_IMAGE_TAG}"
webhook:
  create: ${webhook_create}
  resources:
    requests: { cpu: 25m, memory: 32Mi }
    limits: { cpu: 100m, memory: 64Mi }
  image:
    repository: ${ESO_IMAGE_REPOSITORY}
    tag: "${ESO_IMAGE_TAG}"
certController:
  create: ${cert_create}
  resources:
    requests: { cpu: 25m, memory: 32Mi }
    limits: { cpu: 100m, memory: 64Mi }
  image:
    repository: ${ESO_IMAGE_REPOSITORY}
    tag: "${ESO_IMAGE_TAG}"
VALUESEOF
}

# One row per scoped controller release: env name | operator namespace |
# release name | webhook create | cert-controller create. eso-staging
# is the fixed, arbitrary owner of the cluster-wide webhook/cert-
# controller singletons (see the file header) - eso-production never
# creates either.
eso_environments() {
  cat <<'EOF'
staging|eso-staging|eso-staging|true|true
production|eso-production|eso-production|false|false
EOF
}

eso_release_exists() {
  ns="$1"; release="$2"
  phelm list -n "$ns" -o json 2>/dev/null | grep -q "\"name\":\"${release}\""
}

# Verifies, via metadata only (never a name-prefix guess), that a
# namespaced object ($1 in "<resourcetype-with-group>/<name>" form, $2
# its namespace) is owned by one of the two KNOWN, currently-deployed
# ESO scoped releases (from eso_environments()) - i.e. it is
# legitimately Helm/ESO-owned content, not an unrelated foreign object
# that merely happens to look similar. Checks, in order:
#   - app.kubernetes.io/managed-by == Helm
#   - meta.helm.sh/release-name and meta.helm.sh/release-namespace
#     match exactly one row of eso_environments()
#   - that release actually exists right now (eso_release_exists)
# Backs Phase 2.6.3a's gitops-uninstall classifier
# (scripts/gitops/_lib.sh). Returns 1 (not owned) on any missing/
# mismatched metadata - never guesses.
eso_release_owns_object() {
  restype_name="$1"; ns="$2"
  managed_by="$(pkubectl -n "$ns" get "$restype_name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  [ "$managed_by" = "Helm" ] || return 1
  release_name="$(pkubectl -n "$ns" get "$restype_name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
  release_ns="$(pkubectl -n "$ns" get "$restype_name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)"
  [ -n "$release_name" ] && [ -n "$release_ns" ] || return 1
  while IFS='|' read -r env_name eso_ns eso_release wc cc; do
    [ -z "$env_name" ] && continue
    if [ "$release_name" = "$eso_release" ] && [ "$release_ns" = "$eso_ns" ]; then
      if eso_release_exists "$eso_ns" "$eso_release"; then
        return 0
      fi
    fi
  done <<EOF
$(eso_environments)
EOF
  return 1
}

# Returns 0 if a currently-deployed ESO scoped release's scopedNamespace
# equals $1 - i.e. an ESO controller is ACTIVELY watching that workload
# namespace right now. Backs the Phase 2.6.3a uninstall guard: never
# delete a namespace an active ESO release still depends on for its
# scoped RBAC.
eso_scoped_namespace_active() {
  target_ns="$1"
  while IFS='|' read -r env_name eso_ns eso_release wc cc; do
    [ -z "$env_name" ] && continue
    if [ "$env_name" = "$target_ns" ] && eso_release_exists "$eso_ns" "$eso_release"; then
      return 0
    fi
  done <<EOF
$(eso_environments)
EOF
  return 1
}

# Structural (field-aware) scan for a literal "*" value inside any RBAC
# rule field - apiGroups, resources, verbs, resourceNames,
# nonResourceURLs - across a rendered multi-document manifest. Prints
# one "WILDCARD: ..." line per violation found and returns 1; prints
# nothing and returns 0 if none exist. Deliberately field-aware rather
# than a blind `grep '"\*"'` over the whole file, which would (a) miss
# an unquoted `- *` list item, (b) miss a single-line inline/flow list
# like `resources: ["*"]` or `verbs: [*, get]`, (c) miss a multi-line
# inline list whose closing `]` is on a later line, and (d) can never
# tell which of these five specific fields a matched "*" actually
# belongs to (a `resourceNames` entry that is the literal string "*"
# is exactly the case this must catch; an unrelated key elsewhere in
# the document containing a literal asterisk substring must not be a
# false positive).
#
# Handles:
#   - block list items, quoted or unquoted:      - "*"  |  - '*'  |  - *
#   - single-line inline/flow lists:              resources: ["*", "foo"]
#   - multi-line inline/flow lists spanning until a closing `]`
#   - the key line itself optionally prefixed by "- " (the first key of
#     a `rules:` list entry, e.g. "  - apiGroups:")
eso_check_no_rbac_wildcards() {
  infile="$1"
  awk '
    function strip(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/^"/, "", s); gsub(/"$/, "", s)
      gsub(/^'"'"'/, "", s); gsub(/'"'"'$/, "", s)
      return s
    }
    function is_star(s,    t) {
      t = strip(s)
      return (t == "*")
    }
    function scan_inline(k, body,    n, items, i) {
      n = split(body, items, ",")
      for (i = 1; i <= n; i++) {
        if (items[i] == "") { continue }
        if (is_star(items[i])) {
          print "WILDCARD: inline " k " contains \"*\" at line " NR
          fail = 1
        }
      }
    }
    BEGIN { key = ""; in_inline = 0; inline_key = ""; inline_buf = ""; fail = 0 }

    # already collecting a multi-line inline list - keep buffering until
    # the closing bracket appears.
    in_inline {
      line = $0
      if (line ~ /\]/) {
        sub(/\].*$/, "", line)
        inline_buf = inline_buf line
        scan_inline(inline_key, inline_buf)
        in_inline = 0; inline_buf = ""; inline_key = ""
        next
      }
      inline_buf = inline_buf line ","
      next
    }

    # single-line or multi-line-opening inline/flow list:
    #   key: [ ... ]          (single line)
    #   key: [ ...            (opens, continues below)
    /^[[:space:]]*-?[[:space:]]*(apiGroups|resources|verbs|resourceNames|nonResourceURLs):[[:space:]]*\[/ {
      k = $0; sub(/:.*/, "", k); gsub(/^[[:space:]]*-?[[:space:]]*/, "", k)
      line = $0
      sub(/^[^\[]*\[/, "", line)
      if (line ~ /\]/) {
        sub(/\].*$/, "", line)
        scan_inline(k, line)
      } else {
        in_inline = 1; inline_key = k; inline_buf = line ","
      }
      key = ""
      next
    }

    # block-list key header (optionally "- " prefixed as the first key
    # of a rules[] entry), with nothing after the colon - list items
    # follow on subsequent "- " lines.
    /^[[:space:]]*-?[[:space:]]*(apiGroups|resources|verbs|resourceNames|nonResourceURLs):[[:space:]]*$/ {
      key = $0
      sub(/:[[:space:]]*$/, "", key)
      gsub(/^[[:space:]]*-?[[:space:]]*/, "", key)
      next
    }

    # a block-list item belonging to the current key.
    key != "" && /^[[:space:]]*-[[:space:]]*/ {
      val = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", val)
      if (is_star(val)) {
        print "WILDCARD: " key " contains \"*\" at line " NR
        fail = 1
      }
      next
    }

    # any other real content line (not a list item) ends the current
    # block-list key context.
    /^[[:space:]]*[^[:space:]#-]/ { key = "" }
    /^[[:space:]]*-[[:space:]]*[a-zA-Z]/ && key != "" {
      # a "- somethingElse:" line that is not one of the five tracked
      # keys also ends the block-list context (new rules[] entry).
      if ($0 !~ /(apiGroups|resources|verbs|resourceNames|nonResourceURLs):/) { key = "" }
    }

    END { exit fail }
  ' "$infile"
}
