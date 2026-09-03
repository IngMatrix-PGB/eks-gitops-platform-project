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

require_helm() {
  if [ ! -x "$HELM_BIN" ]; then
    echo "FAIL: $HELM_BIN not found or not executable - run 'make tools-install' first" >&2
    exit 1
  fi
}

# Explicit helm wrapper: project-local binary, isolated config/cache/data
# under .local/helm/, project-local kubeconfig - never global state.
phelm() {
  HELM_CONFIG_HOME=".local/helm/config" \
  HELM_CACHE_HOME=".local/helm/cache" \
  HELM_DATA_HOME=".local/helm/data" \
  HELM_REGISTRY_CONFIG=".local/helm/config/registry/config.json" \
  KUBECONFIG="$PROJECT_KUBECONFIG" \
    "$HELM_BIN" --kubeconfig "$PROJECT_KUBECONFIG" "$@"
}

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
