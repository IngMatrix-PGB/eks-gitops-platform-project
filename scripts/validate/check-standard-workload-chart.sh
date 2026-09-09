#!/bin/sh
# Fully offline validation of charts/standard-workload: lint + render for
# both environments, deterministic post-merge negative schema fixtures
# (built at runtime under mktemp -d, never a literal fixture file),
# digest-only image enforcement, Restricted-PSS field presence, a
# rendered-kind allowlist, proof no Secret renders, proof no deferred
# optional resource (Ingress/HPA/PDB/NetworkPolicy/ServiceMonitor)
# renders or is schema-exposed, and a client-side kubectl dry-run for
# both environments. Never touches a cluster. Backs
# `make check-standard-workload-chart` (wired into `make validate`).
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
require_tools

CHART="charts/standard-workload"
HELM=".tools/bin/helm"
KUBECTL=".tools/bin/kubectl"
fail=0

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM

echo "check-standard-workload-chart: helm lint (staging) ..."
if ! "$HELM" lint "$CHART" -f "$CHART/values-staging.yaml"; then
  echo "FAIL: helm lint failed for staging" >&2
  fail=1
fi

echo "check-standard-workload-chart: helm lint (production) ..."
if ! "$HELM" lint "$CHART" -f "$CHART/values-production.yaml"; then
  echo "FAIL: helm lint failed for production" >&2
  fail=1
fi

render_staging="$root/staging.yaml"
render_production="$root/production.yaml"

echo "check-standard-workload-chart: helm template (staging) ..."
# --namespace matters as of Phase 2.6.2: templates/secretstore.yaml
# reads .Release.Namespace for the auth ServiceAccount reference, which
# `helm template` otherwise defaults to "default" - not representative
# of how Argo CD actually renders this chart (always with the
# Application's real destination namespace). Passing it here makes the
# offline render match the real deployed shape.
if ! "$HELM" template platform-smoke-staging "$CHART" -f "$CHART/values-staging.yaml" --namespace staging > "$render_staging" 2>&1; then
  echo "FAIL: helm template failed for staging" >&2
  cat "$render_staging" >&2
  fail=1
fi

echo "check-standard-workload-chart: helm template (production) ..."
if ! "$HELM" template platform-smoke-production "$CHART" -f "$CHART/values-production.yaml" --namespace production > "$render_production" 2>&1; then
  echo "FAIL: helm template failed for production" >&2
  cat "$render_production" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (cannot continue without both renders)" >&2
  exit 1
fi

# --- rendered-kind allowlist: exactly ConfigMap, Deployment,
# ExternalSecret, SecretStore, Service, ServiceAccount (as of Phase
# 2.6.2 - two ServiceAccount objects render: the workload's own and the
# SecretStore's dedicated auth identity) ---
for render in "$render_staging" "$render_production"; do
  kinds="$(grep -E '^kind: ' "$render" | sort -u)"
  expected="$(printf 'kind: ConfigMap\nkind: Deployment\nkind: ExternalSecret\nkind: SecretStore\nkind: Service\nkind: ServiceAccount')"
  if [ "$kinds" != "$expected" ]; then
    echo "FAIL: $render rendered an unexpected kind set:" >&2
    echo "$kinds" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: rendered-kind allowlist matches exactly (ConfigMap, Deployment, ExternalSecret, SecretStore, Service, ServiceAccount) in both environments"

# --- no Secret renders ---
for render in "$render_staging" "$render_production"; do
  if grep -q '^kind: Secret$' "$render"; then
    echo "FAIL: $render rendered a Secret - not authorized in Phase 2.4" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no Secret rendered in either environment"

# --- deferred optional resources: must not render and must not be schema-exposed ---
for kind in Ingress HorizontalPodAutoscaler PodDisruptionBudget NetworkPolicy ServiceMonitor; do
  for render in "$render_staging" "$render_production"; do
    if grep -q "^kind: ${kind}$" "$render"; then
      echo "FAIL: $render rendered $kind - deferred capability must not render in Phase 2.4" >&2
      fail=1
    fi
  done
done
for key in ingress autoscaling podDisruptionBudget networkPolicy serviceMonitor; do
  if grep -qE "\"${key}\"" "$CHART/values.schema.json"; then
    echo "FAIL: values.schema.json exposes deferred key '$key' - dead configuration is not authorized" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no deferred optional resource renders or is schema-exposed"

# --- image digest-only enforcement ---
for render in "$render_staging" "$render_production"; do
  if grep -E '^\s*image: ' "$render" | grep -v '@sha256:' >/dev/null 2>&1; then
    echo "FAIL: $render contains a tag-only (non-digest) image reference" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: every rendered image reference is digest-pinned"

# --- Restricted PSS field presence (grep-based, matches lab/argocd/render.sh style) ---
for render in "$render_staging" "$render_production"; do
  for needle in "runAsNonRoot: true" "runAsUser: 65532" "runAsGroup: 65532" "allowPrivilegeEscalation: false" "readOnlyRootFilesystem: true" "- ALL" "seccompProfile" "type: RuntimeDefault" "automountServiceAccountToken: false"; do
    if ! grep -qF -- "$needle" "$render"; then
      echo "FAIL: $render is missing expected Restricted-PSS field: $needle" >&2
      fail=1
    fi
  done
done
[ "$fail" -eq 0 ] && echo "OK: Restricted-PSS fields present in both rendered environments"

# --- Service selector matches Deployment pod-template labels (duplicate/mismatch guard) ---
#
# Phase 3.2.1: structural (indentation-bounded) extraction, replacing
# the previous "selector:"-to-"ports:" / "template:"-to-"annotations:"
# sed ranges, which silently broke if either literal next-sibling key
# ever changed or moved. yaml_indented_block locates a key line, records
# ITS OWN indentation, and returns exactly the lines nested strictly
# more than that - the real YAML rule for "this mapping has ended" -
# never assuming what key (if any) comes next. Verified byte-for-byte
# equivalent output against this chart's real staging/production
# renders before this change was made.
#
# yaml_indented_block <key-line, trimmed> - reads a YAML document on
# stdin, prints the body of the first mapping/sequence whose own key
# line (after trimming leading whitespace) equals <key-line>.
yaml_indented_block() {
  key="$1"
  awk -v key="$key" '
  {
    line = $0
    t = line
    sub(/^[ \t]*/, "", t)
    if (t == "") next
    match(line, /^[ \t]*/)
    ind = RLENGTH
    if (anchor_indent == "") {
      if (t == key) { anchor_indent = ind }
      next
    }
    if (ind <= anchor_indent) exit
    print
  }'
}

for render in "$render_staging" "$render_production"; do
  # "kind: X" and the "---" document separator are real YAML/Kubernetes
  # structural markers (not a heuristic), so isolating each resource's
  # own document this way is already correct - only the two sed ranges
  # inside each document were fragile, and are what changed above.
  svc_doc="$(awk '/^kind: Service$/,/^---$/' "$render")"
  svc_sel="$(printf '%s\n' "$svc_doc" | yaml_indented_block 'selector:' | grep 'app.kubernetes.io' | sort)"
  dep_doc="$(awk '/^kind: Deployment$/,0' "$render")"
  # Narrow to spec.template first: the Deployment's OWN metadata.labels
  # (a sibling, higher up the document) also contains a "labels:" key -
  # narrowing to the template: block first is what makes the second
  # yaml_indented_block call find spec.template.metadata.labels and not
  # metadata.labels.
  dep_template="$(printf '%s\n' "$dep_doc" | yaml_indented_block 'template:')"
  dep_labels="$(printf '%s\n' "$dep_template" | yaml_indented_block 'labels:' | grep 'app.kubernetes.io' | sort)"
  for line in $(printf '%s\n' "$svc_sel" | tr -d ' '); do
    if ! printf '%s\n' "$dep_labels" | tr -d ' ' | grep -qF "$line"; then
      echo "FAIL: $render Service selector entry '$line' not found among Deployment pod-template labels" >&2
      fail=1
    fi
  done
done
[ "$fail" -eq 0 ] && echo "OK: Service selectors match Deployment pod-template labels in both environments"

# --- Phase 2.6.2: default render (externalSecret.enabled left at the
# chart's own values.yaml default: false) must be exactly the pre-
# Phase-2.6.2 shape - the same 4 kinds, no SecretStore/ExternalSecret/
# extra ServiceAccount, no "secret" volume or volumeMount. This is the
# single most important check in this whole file: it proves nothing
# regresses for any values file that never opts in. ---
default_render="$root/default.yaml"
if ! "$HELM" template default-render "$CHART" --namespace default > "$default_render" 2>&1; then
  echo "FAIL: helm template failed for the chart's own bare defaults" >&2
  cat "$default_render" >&2
  fail=1
else
  default_kinds="$(grep -E '^kind: ' "$default_render" | sort -u)"
  default_expected="$(printf 'kind: ConfigMap\nkind: Deployment\nkind: Service\nkind: ServiceAccount')"
  if [ "$default_kinds" != "$default_expected" ]; then
    echo "FAIL: default render (externalSecret.enabled: false) rendered an unexpected kind set:" >&2
    echo "$default_kinds" >&2
    fail=1
  elif grep -q 'name: secret' "$default_render"; then
    echo "FAIL: default render (externalSecret.enabled: false) still renders a 'secret' volume/mount" >&2
    fail=1
  else
    echo "OK: default render (externalSecret.enabled: false) is exactly the pre-Phase-2.6.2 4-kind shape, no secret volume/mount"
  fi
fi

# --- no Secret is ever rendered by this chart (the target Secret is
# created by ESO, never by any template) ---
for render in "$render_staging" "$render_production"; do
  if grep -q '^kind: Secret$' "$render"; then
    echo "FAIL: $render rendered a Secret manifest - not authorized; the target Secret must be ESO-managed only" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no Secret manifest rendered in either environment (target Secret is ESO-managed only)"

# --- SecretStore is always namespaced, never ClusterSecretStore ---
for render in "$render_staging" "$render_production"; do
  if grep -q '^kind: ClusterSecretStore$' "$render"; then
    echo "FAIL: $render rendered a ClusterSecretStore - only a namespaced SecretStore is authorized" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no ClusterSecretStore rendered in either environment"

# --- the workload container never consumes the secret via env,
# envFrom, or secretKeyRef - read-only file mount only ---
for render in "$render_staging" "$render_production"; do
  if grep -qE '^\s*envFrom:' "$render"; then
    echo "FAIL: $render uses envFrom - the secret must only ever be consumed as a read-only file mount" >&2
    fail=1
  fi
  if grep -q 'secretKeyRef:' "$render"; then
    echo "FAIL: $render uses secretKeyRef - the secret must only ever be consumed as a read-only file mount" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no envFrom/secretKeyRef in either environment - the secret is never exposed via environment variables"

# --- the secret volumeMount is read-only ---
for render in "$render_staging" "$render_production"; do
  if ! awk '/- name: secret$/{f=1} f && /mountPath:/{print; exit}' "$render" | grep -q .; then
    echo "FAIL: $render has no 'secret' volumeMount" >&2
    fail=1
  fi
done
if grep -A2 '            - name: secret$' "$render_staging" | grep -q 'readOnly: true' \
  && grep -A2 '            - name: secret$' "$render_production" | grep -q 'readOnly: true'; then
  echo "OK: the secret volumeMount is readOnly: true in both environments"
else
  echo "FAIL: the secret volumeMount is not readOnly: true in one or both environments" >&2
  fail=1
fi

# --- staging/production isolation: the two rendered environments must
# never share a SecretStore name, source namespace, source Secret name,
# or auth ServiceAccount name. Extracted from the isolated SecretStore
# document only (bounded by its own "kind: SecretStore" ... next "---"
# separator), since "kind: SecretStore" also appears as the literal
# value of ExternalSecret's own secretStoreRef.kind field elsewhere in
# the same file - a plain grep -A/-B against the whole file cannot tell
# those two occurrences apart. ---
secretstore_block() {
  awk '/^kind: SecretStore$/,0' "$1" | awk '/^---$/{exit} {print}'
}
staging_secretstore="$(secretstore_block "$render_staging" | grep 'name:' | head -1 | awk '{print $2}')"
production_secretstore="$(secretstore_block "$render_production" | grep 'name:' | head -1 | awk '{print $2}')"
staging_source_ns="$(secretstore_block "$render_staging" | grep 'remoteNamespace:' | awk '{print $2}')"
production_source_ns="$(secretstore_block "$render_production" | grep 'remoteNamespace:' | awk '{print $2}')"
staging_source_key="$(grep -A1 'remoteRef:' "$render_staging" | grep 'key:' | awk '{print $2}')"
production_source_key="$(grep -A1 'remoteRef:' "$render_production" | grep 'key:' | awk '{print $2}')"
staging_auth_sa="$(secretstore_block "$render_staging" | grep -A1 'serviceAccount:' | grep 'name:' | awk '{print $2}')"
production_auth_sa="$(secretstore_block "$render_production" | grep -A1 'serviceAccount:' | grep 'name:' | awk '{print $2}')"
isolation_fail=0
[ "$staging_secretstore" = "$production_secretstore" ] && { echo "FAIL: staging and production share the same SecretStore name '$staging_secretstore'" >&2; isolation_fail=1; }
[ "$staging_source_ns" = "$production_source_ns" ] && { echo "FAIL: staging and production share the same source namespace '$staging_source_ns'" >&2; isolation_fail=1; }
[ "$staging_source_key" = "$production_source_key" ] && { echo "FAIL: staging and production share the same source Secret name '$staging_source_key'" >&2; isolation_fail=1; }
[ "$staging_auth_sa" = "$production_auth_sa" ] && { echo "FAIL: staging and production share the same auth ServiceAccount name '$staging_auth_sa'" >&2; isolation_fail=1; }
if [ "$isolation_fail" -ne 0 ]; then
  fail=1
else
  echo "OK: staging and production have fully distinct SecretStore/source-namespace/source-Secret/auth-ServiceAccount names"
fi

# --- kubectl itself must be present, executable, and version-capable
# before it is trusted for anything below. A wrong-platform or corrupt
# binary (the "Exec format error" incident this check exists to catch)
# must fail loudly here - it must never be allowed to masquerade as "no
# cluster reachable" the way it did before this fix. ---
if [ ! -x "$KUBECTL" ]; then
  echo "FAIL: $KUBECTL not found or not executable - run 'make tools-install' first" >&2
  fail=1
elif ! "$KUBECTL" version --client >/dev/null 2>&1; then
  echo "FAIL: $KUBECTL is present but did not execute successfully (missing, incompatible, or wrong-platform binary) - run 'make tools-install'" >&2
  fail=1
else
  echo "OK: $KUBECTL is executable and reports a client version"

  # --- client-side kubectl dry-run (never mutates anything; used as a
  # structural/schema oracle only when a real cluster is reachable) ---
  # Verified empirically: kubectl v1.36.4's --dry-run=client still
  # requires live API discovery (RESTMapper resolution) even with
  # --validate=false - there is no fully offline fallback in this
  # kubectl version. --dry-run=client itself guarantees no object is
  # ever persisted, so pointing it at the project's own real kind
  # cluster is safe (identical guarantee to every other
  # --dry-run=client use already in this repository) - it is used here
  # purely as a schema oracle, never as a mutation. Once kubectl itself
  # is proven functional above, the only remaining reason to skip is a
  # genuine absence of a project cluster in this environment (expected
  # in CI, which never runs `make lab-create`) - never a broken binary.
  if [ ! -f "$PROJECT_KUBECONFIG" ]; then
    echo "SKIP: no $PROJECT_KUBECONFIG in this environment (expected in CI, which never creates a project cluster); kubectl itself is verified functional above, and helm lint/template, the rendered-kind allowlist, and the schema regression matrix already cover structural correctness"
  elif ! pkubectl get --raw /healthz >/dev/null 2>&1; then
    echo "SKIP: $PROJECT_KUBECONFIG exists but the project cluster is not currently reachable; kubectl itself is verified functional above, and helm lint/template, the rendered-kind allowlist, and the schema regression matrix already cover structural correctness"
  else
    for render in "$render_staging" "$render_production"; do
      if ! pkubectl apply --dry-run=client -f "$render" >/dev/null 2>&1; then
        echo "FAIL: kubectl dry-run=client (against the project cluster, as a schema oracle only - nothing is persisted) rejected $render" >&2
        pkubectl apply --dry-run=client -f "$render" >&2 || true
        fail=1
      fi
    done
    [ "$fail" -eq 0 ] && echo "OK: client-side kubectl dry-run passed for both environments (project cluster used as schema oracle, no mutation)"
  fi
fi

# --- deterministic negative schema regression (post-merge, values built at runtime) ---
run_negative_case() {
  desc="$1"; fixture_content="$2"
  fixture="$root/fixture-$$.yaml"
  printf '%s\n' "$fixture_content" > "$fixture"
  set +e
  lint_out="$("$HELM" lint "$CHART" -f "$CHART/values-staging.yaml" -f "$fixture" 2>&1)"
  lint_rc=$?
  tmpl_out="$("$HELM" template x "$CHART" -f "$CHART/values-staging.yaml" -f "$fixture" 2>&1)"
  tmpl_rc=$?
  set -e
  rm -f "$fixture"
  if [ "$lint_rc" -eq 0 ] || [ "$tmpl_rc" -eq 0 ]; then
    echo "FAIL: negative case '$desc' did not fail (lint_rc=$lint_rc tmpl_rc=$tmpl_rc) - schema did not reject it" >&2
    fail=1
    return
  fi
  if ! printf '%s' "$lint_out$tmpl_out" | grep -qi "does not meet the specifications of the schema\|don't meet the specifications of the schema"; then
    echo "FAIL: negative case '$desc' failed for a reason other than schema validation" >&2
    printf '%s\n%s\n' "$lint_out" "$tmpl_out" >&2
    fail=1
    return
  fi
  echo "OK: negative case '$desc' correctly rejected by values.schema.json"
}

# Phase 3.3.3: run_negative_case always layers its fixture on top of
# values-staging.yaml, which sets sourceNamespace/sourceSecretName/
# authServiceAccountName to real, non-default values - correct for a
# "kubernetes" provider case (or one deliberately proving those values
# leak through as a violation under "aws" - see the case that does
# exactly that below), but wrong for an aws-provider case meant to
# demonstrate one single, exact defect: layering on values-staging.yaml
# would ALSO trip the aws-branch's kubernetes-field exclusion rules,
# masking the one defect under test behind an unrelated one and
# violating "cada fixture debe demostrar la causa exacta del rechazo".
# This variant instead builds a complete, standalone aws-profile
# fixture (values.yaml's own base + this fixture only, never values-
# staging.yaml) so the only possible violation is the one deliberately
# introduced, and asserts none of the three kubernetes-only field names
# appear in the error output as extra corroboration.
run_negative_case_aws() {
  desc="$1"; external_secret_block="$2"
  fixture="$root/aws-negative-$$.yaml"
  cat > "$fixture" <<FIXEOF
image:
  repository: ghcr.io/stefanprodan/podinfo
  digest: "sha256:ec73780a8425f59ea49f5bc8cdff0d598805a224fbaa1f86c67a244f250fa9da"
replicaCount: 1
resources:
  requests: { cpu: 25m, memory: 32Mi }
  limits: { cpu: 100m, memory: 64Mi }
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile: { type: RuntimeDefault }
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
serviceAccount:
  automountServiceAccountToken: false
service:
  port: 9898
configMap:
  uiMessage: "negative case fixture"
${external_secret_block}
FIXEOF
  set +e
  lint_out="$("$HELM" lint "$CHART" -f "$fixture" 2>&1)"
  lint_rc=$?
  tmpl_out="$("$HELM" template x "$CHART" -f "$fixture" 2>&1)"
  tmpl_rc=$?
  set -e
  rm -f "$fixture"
  if [ "$lint_rc" -eq 0 ] || [ "$tmpl_rc" -eq 0 ]; then
    echo "FAIL: negative case '$desc' did not fail (lint_rc=$lint_rc tmpl_rc=$tmpl_rc) - schema did not reject it" >&2
    fail=1
    return
  fi
  combined="$lint_out$tmpl_out"
  if ! printf '%s' "$combined" | grep -qi "does not meet the specifications of the schema\|don't meet the specifications of the schema"; then
    echo "FAIL: negative case '$desc' failed for a reason other than schema validation" >&2
    printf '%s\n%s\n' "$lint_out" "$tmpl_out" >&2
    fail=1
    return
  fi
  if printf '%s' "$combined" | grep -qE "sourceNamespace|sourceSecretName|authServiceAccountName"; then
    echo "FAIL: negative case '$desc' also reported an unrelated kubernetes-field violation - fixture is not isolated, cannot confirm the exact cause" >&2
    printf '%s\n' "$combined" >&2
    fail=1
    return
  fi
  echo "OK: negative case '$desc' correctly rejected by values.schema.json (isolated aws-profile fixture, no unrelated violation)"
}

run_negative_case "malformed digest" 'image:
  repository: ghcr.io/stefanprodan/podinfo
  digest: "sha256:zzzz"'

run_negative_case "empty digest" 'image:
  repository: ghcr.io/stefanprodan/podinfo
  digest: ""'

run_negative_case "null digest" 'image:
  repository: ghcr.io/stefanprodan/podinfo
  digest: null'

run_negative_case "missing repository" 'image:
  repository: null
  digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"'

run_negative_case "invalid repository" 'image:
  repository: ""
  digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"'

run_negative_case "replica count zero" 'replicaCount: 0'

run_negative_case "UID zero" 'podSecurityContext:
  runAsNonRoot: true
  runAsUser: 0
  runAsGroup: 65532
  fsGroup: 65532
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault'

run_negative_case "GID zero" 'podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 0
  fsGroup: 65532
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault'

run_negative_case "privilege escalation re-enabled" 'containerSecurityContext:
  allowPrivilegeEscalation: true
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]'

run_negative_case "writable rootfs re-enabled" 'containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false
  capabilities:
    drop: ["ALL"]'

run_negative_case "capabilities not fully dropped" 'containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: []'

run_negative_case "missing resource requests" 'resources:
  requests: null
  limits:
    cpu: 100m
    memory: 64Mi'

run_negative_case "missing resource limits" 'resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits: null'

run_negative_case "externalSecret enabled without secretStoreName" 'externalSecret:
  enabled: true
  secretStoreName: null
  sourceNamespace: "eso-source-staging"
  sourceSecretName: "local-backend-staging"
  sourceProperty: "message"
  authServiceAccountName: "staging-secretstore-reader"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288'

run_negative_case "externalSecret with an unknown extra property" 'externalSecret:
  enabled: true
  secretStoreName: "staging-kubernetes-backend"
  sourceNamespace: "eso-source-staging"
  sourceSecretName: "local-backend-staging"
  sourceProperty: "message"
  authServiceAccountName: "staging-secretstore-reader"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  notAllowed: "nope"'

# =============================================================================
# Phase 3.3.1: externalSecret.provider dual-provider contract
# (kubernetes|aws). Schema/template contract only - no AWS account
# exists, no cluster is used as an oracle for the "aws" provider (unlike
# the kubernetes-provider dry-run above, which legitimately targets the
# project's own kind cluster). All AWS-side data below is synthetic and
# public (a fake region-shaped string, a logical secret name) - never a
# real account ID, ARN, or credential.
# =============================================================================

# --- positive: a full standalone AWS-provider render, staging and
# production, each with its own distinct secretStoreName/region/
# secretName (mirrors the same never-shared-identity convention as the
# real kubernetes-provider values-staging.yaml/values-production.yaml).
# Built as a complete values file (not layered on values-staging.yaml,
# which carries real kubernetes-only fields as non-default values that
# would - correctly - trip the schema's provider-exclusivity rules; see
# the negative case below that deliberately does layer on it). ---
aws_fixture() {
  env_name="$1"; store="$2"; region="$3"; secret_name="$4"
  cat <<EOF
image:
  repository: ghcr.io/stefanprodan/podinfo
  digest: "sha256:ec73780a8425f59ea49f5bc8cdff0d598805a224fbaa1f86c67a244f250fa9da"
replicaCount: 1
resources:
  requests: { cpu: 25m, memory: 32Mi }
  limits: { cpu: 100m, memory: 64Mi }
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile: { type: RuntimeDefault }
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
serviceAccount:
  automountServiceAccountToken: false
service:
  port: 9898
configMap:
  uiMessage: "aws provider fixture (${env_name})"
externalSecret:
  enabled: true
  provider: "aws"
  secretStoreName: "${store}"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    region: "${region}"
    secretName: "${secret_name}"
EOF
}

aws_staging_fixture="$root/aws-staging-fixture.yaml"
aws_production_fixture="$root/aws-production-fixture.yaml"
aws_fixture "staging" "staging-aws-backend" "us-east-1" "eks-gitops-platform-project/staging/backend" > "$aws_staging_fixture"
aws_fixture "production" "production-aws-backend" "us-east-1" "eks-gitops-platform-project/production/backend" > "$aws_production_fixture"

aws_render_staging="$root/aws-staging.yaml"
aws_render_production="$root/aws-production.yaml"
echo "check-standard-workload-chart: helm lint (aws provider, staging fixture) ..."
if ! "$HELM" lint "$CHART" -f "$aws_staging_fixture"; then
  echo "FAIL: helm lint failed for the aws-provider staging fixture" >&2
  fail=1
fi
echo "check-standard-workload-chart: helm lint (aws provider, production fixture) ..."
if ! "$HELM" lint "$CHART" -f "$aws_production_fixture"; then
  echo "FAIL: helm lint failed for the aws-provider production fixture" >&2
  fail=1
fi
echo "check-standard-workload-chart: helm template (aws provider, staging fixture) ..."
if ! "$HELM" template platform-smoke-staging-aws "$CHART" -f "$aws_staging_fixture" --namespace staging > "$aws_render_staging" 2>&1; then
  echo "FAIL: helm template failed for the aws-provider staging fixture" >&2
  cat "$aws_render_staging" >&2
  fail=1
fi
echo "check-standard-workload-chart: helm template (aws provider, production fixture) ..."
if ! "$HELM" template platform-smoke-production-aws "$CHART" -f "$aws_production_fixture" --namespace production > "$aws_render_production" 2>&1; then
  echo "FAIL: helm template failed for the aws-provider production fixture" >&2
  cat "$aws_render_production" >&2
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED before the aws-provider content checks" >&2
  exit 1
fi
echo "OK: aws-provider staging and production fixtures both lint and render successfully"

# --- positive: aws-provider rendered-kind allowlist. Exactly one
# ServiceAccount (the workload's own) - unlike the kubernetes provider,
# no dedicated auth ServiceAccount is rendered, since Pod Identity
# authenticates the ESO controller's own pod, never a per-SecretStore
# identity. ---
for render in "$aws_render_staging" "$aws_render_production"; do
  kinds="$(grep -E '^kind: ' "$render" | sort)"
  expected="$(printf 'kind: ConfigMap\nkind: Deployment\nkind: ExternalSecret\nkind: SecretStore\nkind: Service\nkind: ServiceAccount')"
  if [ "$kinds" != "$expected" ]; then
    echo "FAIL: $render (aws provider) rendered an unexpected kind set:" >&2
    echo "$kinds" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: aws-provider rendered-kind allowlist matches exactly (one ServiceAccount, no extra auth identity) in both environments"

# --- positive: no Secret ever rendered by the aws provider either ---
for render in "$aws_render_staging" "$aws_render_production"; do
  if grep -q '^kind: Secret$' "$render"; then
    echo "FAIL: $render (aws provider) rendered a Secret manifest - not authorized" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no Secret manifest rendered by the aws provider in either environment"

# --- positive: SecretStore AWS shape - service/region present, auth
# completely absent, and no serviceAccountRef/role/externalID/static
# credential field anywhere in the render (contract-wide, not just
# inside the SecretStore document - a stray field in any other document
# would be just as much a violation). ---
for render in "$aws_render_staging" "$aws_render_production"; do
  store_doc="$(awk '/^kind: SecretStore$/,/^---$/' "$render")"
  if ! printf '%s\n' "$store_doc" | grep -qE '^[[:space:]]*service: SecretsManager$'; then
    echo "FAIL: $render (aws provider) SecretStore missing spec.provider.aws.service: SecretsManager" >&2
    fail=1
  fi
  if ! printf '%s\n' "$store_doc" | grep -qE '^[[:space:]]*region: [^[:space:]]+$'; then
    echo "FAIL: $render (aws provider) SecretStore missing an explicit spec.provider.aws.region" >&2
    fail=1
  fi
  if grep -qE '^[[:space:]]*auth:[[:space:]]*$|serviceAccountRef|^[[:space:]]*role:|externalID|accessKeyID|secretAccessKey|sessionToken' "$render"; then
    echo "FAIL: $render (aws provider) contains a forbidden auth/serviceAccountRef/role/externalID/static-credential field" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: aws-provider SecretStore has service/region set and zero auth/serviceAccountRef/role/externalID/static-credential fields in either environment"

# --- positive: region and remote key are exactly the configured
# synthetic values (proves the schema's aws.region/aws.secretName
# actually flow through to the render, not merely "present in the
# values file and never consumed" - the "no dead configuration" bar the
# kubernetes-provider fields are already held to) ---
staging_region="$(awk '/^kind: SecretStore$/,/^---$/' "$aws_render_staging" | sed -n 's/^[[:space:]]*region: //p')"
production_region="$(awk '/^kind: SecretStore$/,/^---$/' "$aws_render_production" | sed -n 's/^[[:space:]]*region: //p')"
staging_remote_key="$(awk '/^kind: ExternalSecret$/,/^---$/' "$aws_render_staging" | sed -n 's/^[[:space:]]*key: //p')"
production_remote_key="$(awk '/^kind: ExternalSecret$/,/^---$/' "$aws_render_production" | sed -n 's/^[[:space:]]*key: //p')"
if [ "$staging_region" = "us-east-1" ] && [ "$production_region" = "us-east-1" ]; then
  echo "OK: aws-provider SecretStore region matches the configured value in both environments"
else
  echo "FAIL: aws-provider SecretStore region mismatch (staging='$staging_region' production='$production_region')" >&2
  fail=1
fi
if [ "$staging_remote_key" = "eks-gitops-platform-project/staging/backend" ] && [ "$production_remote_key" = "eks-gitops-platform-project/production/backend" ]; then
  echo "OK: aws-provider ExternalSecret remoteRef.key is the configured logical secret name (never an ARN) in both environments"
else
  echo "FAIL: aws-provider remoteRef.key mismatch (staging='$staging_remote_key' production='$production_remote_key')" >&2
  fail=1
fi

# --- positive: staging and production aws-provider identities remain
# distinct (same never-shared-identity bar as the kubernetes provider) ---
if [ "$staging_remote_key" = "$production_remote_key" ]; then
  echo "FAIL: aws-provider staging and production share the same remote secret name '$staging_remote_key'" >&2
  fail=1
else
  echo "OK: aws-provider staging and production have distinct remote secret names"
fi

# --- positive: ExternalSecret points at the correct SecretStore (same
# name this environment's own aws_fixture configured) ---
for pair in "$aws_render_staging:staging-aws-backend" "$aws_render_production:production-aws-backend"; do
  render="${pair%%:*}"; expected_store="${pair##*:}"
  # secretStoreRef.name, not metadata.name (which appears earlier in
  # the same document with the same "name:" key) - narrow to the
  # secretStoreRef: block first, same disambiguation technique as the
  # Deployment metadata.labels vs. spec.template.metadata.labels fix
  # above.
  actual_store="$(awk '/^kind: ExternalSecret$/,/^---$/' "$render" | awk '/secretStoreRef:/{f=1} f && /name:/{print; exit}' | sed -n 's/^[[:space:]]*name: //p')"
  if [ "$actual_store" != "$expected_store" ]; then
    echo "FAIL: $render (aws provider) ExternalSecret.spec.secretStoreRef.name='$actual_store', expected '$expected_store'" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: aws-provider ExternalSecret.spec.secretStoreRef.name matches its own environment's SecretStore in both environments"

# --- positive: Deployment consumes the SAME target Secret name via the
# SAME read-only volume/mount shape as the kubernetes provider - proves
# templates/deployment.yaml needed zero changes for this contract ---
for render in "$aws_render_staging" "$aws_render_production"; do
  if ! grep -qE '^[[:space:]]*secretName: .+-secret$' "$render"; then
    echo "FAIL: $render (aws provider) Deployment volume does not reference the chart's own target Secret name" >&2
    fail=1
  fi
  if ! awk '/- name: secret$/{f=1} f && /mountPath:/{print; exit}' "$render" | grep -q .; then
    echo "FAIL: $render (aws provider) has no 'secret' volumeMount" >&2
    fail=1
  fi
done
if grep -A2 '            - name: secret$' "$aws_render_staging" | grep -q 'readOnly: true' \
  && grep -A2 '            - name: secret$' "$aws_render_production" | grep -q 'readOnly: true'; then
  echo "OK: aws-provider secret volumeMount is readOnly: true in both environments, same as the kubernetes provider"
else
  echo "FAIL: aws-provider secret volumeMount is not readOnly: true in one or both environments" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (aws-provider content checks)" >&2
  exit 1
fi

# --- negative: provider contract ---
run_negative_case "unknown provider value" 'externalSecret:
  enabled: true
  provider: "azure"
  secretStoreName: "x"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    region: "us-east-1"
    secretName: "x"'

run_negative_case_aws "aws provider missing region" 'externalSecret:
  enabled: true
  provider: "aws"
  secretStoreName: "x"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    secretName: "x"'

run_negative_case_aws "aws provider missing remote key (secretName)" 'externalSecret:
  enabled: true
  provider: "aws"
  secretStoreName: "x"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    region: "us-east-1"'

run_negative_case_aws "aws provider enabled with no aws block at all (incomplete configuration)" 'externalSecret:
  enabled: true
  provider: "aws"'

run_negative_case "kubernetes provider missing a kubernetes-required field (sourceNamespace)" 'externalSecret:
  enabled: true
  provider: "kubernetes"
  secretStoreName: "x"
  sourceNamespace: null
  sourceSecretName: "local-backend-staging"
  sourceProperty: "message"
  authServiceAccountName: "staging-secretstore-reader"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288'

# Layered on values-staging.yaml (via run_negative_case's own -f
# values-staging.yaml -f <fixture> harness): values-staging.yaml's own
# sourceNamespace/sourceSecretName/authServiceAccountName are real,
# non-default values - switching only "provider" to "aws" here proves
# those real kubernetes-only values are correctly rejected as misplaced
# configuration under the aws profile (not merely "absent", which the
# harmless base-values.yaml defaults already prove is accepted, see the
# positive aws_fixture renders above, which never touch values-
# staging.yaml at all).
run_negative_case "kubernetes-only fields (from values-staging.yaml) present under provider: aws" 'externalSecret:
  provider: "aws"
  aws:
    region: "us-east-1"
    secretName: "x"'

run_negative_case "aws block present under provider: kubernetes" 'externalSecret:
  enabled: true
  provider: "kubernetes"
  secretStoreName: "x"
  sourceNamespace: "eso-source-staging"
  sourceSecretName: "local-backend-staging"
  sourceProperty: "message"
  authServiceAccountName: "staging-secretstore-reader"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    region: "us-east-1"
    secretName: "x"'

# --- negative: none of these ever become part of the contract, for
# either provider - each must be rejected as an unknown property (never
# defined as a schema property at all, matching the EKS Pod Identity
# contract's own explicit exclusions) ---
for field_case in \
  'auth block:auth: {}' \
  'serviceAccountRef:serviceAccountRef: { name: "x" }' \
  'role:role: "arn:aws:iam::aws:role/x"' \
  'externalID:externalID: "x"' \
  'AWS access key ID:accessKeyID: "not-a-real-access-key-id"' \
  'AWS secret access key:secretAccessKey: "fake-not-a-real-secret"' \
  'AWS session token:sessionToken: "fake-not-a-real-token"' \
  ; do
  desc="${field_case%%:*}"
  kv="${field_case#*:}"
  run_negative_case_aws "$desc under externalSecret (aws profile)" "externalSecret:
  enabled: true
  provider: \"aws\"
  secretStoreName: \"x\"
  refreshInterval: \"1m\"
  key: \"message\"
  mountPath: \"/etc/secret\"
  fileName: \"message\"
  defaultMode: 288
  aws:
    region: \"us-east-1\"
    secretName: \"x\"
  $kv"
done

# =============================================================================
# Phase 3.3.2-3.3.3: statically validated aws-eks profile overlays
# (values-staging-aws.yaml/values-production-aws.yaml) and Terraform<->
# GitOps cross-validation. No Terraform state, no AWS account, no
# cluster - every fact compared below comes from either this chart's
# own render or a literal grepped directly out of terraform/envs/
# identity/variables.tf (never re-typed as a duplicated policy, so a
# future change to that file cannot silently drift out of sync with
# this check without also failing it).
# =============================================================================

TF_IDENTITY_VARS="terraform/envs/identity/variables.tf"

# tf_default <variable-name> - the exact literal `default = "..."`
# value for that variable block in $TF_IDENTITY_VARS.
tf_default() {
  var="$1"
  awk -v v="variable \"$var\"" '$0 ~ v {f=1} f {print} f && /^}/{exit}' "$TF_IDENTITY_VARS" \
    | sed -n 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p'
}

# tf_region_regex - the exact regex string Terraform's own aws_region
# variable validates against (terraform/envs/identity/variables.tf) -
# reused directly, never hand-copied, so a future change to that regex
# automatically flows into this check.
tf_region_regex() {
  awk '/^variable "aws_region"/,/^}/' "$TF_IDENTITY_VARS" | sed -n 's/.*regex("\([^"]*\)".*/\1/p'
}

tf_staging_secret_name="$(tf_default staging_secret_name)"
tf_production_secret_name="$(tf_default production_secret_name)"
tf_staging_namespace="$(tf_default staging_namespace)"
tf_staging_service_account="$(tf_default staging_service_account)"
tf_production_namespace="$(tf_default production_namespace)"
tf_production_service_account="$(tf_default production_service_account)"
tf_aws_region_regex="$(tf_region_regex)"

for name in tf_staging_secret_name tf_production_secret_name tf_staging_namespace \
  tf_staging_service_account tf_production_namespace tf_production_service_account tf_aws_region_regex; do
  eval "val=\$$name"
  if [ -z "$val" ]; then
    echo "FAIL: could not extract $name from $TF_IDENTITY_VARS - Terraform<->GitOps cross-validation cannot proceed" >&2
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (Terraform variable extraction)" >&2
  exit 1
fi
echo "OK: extracted staging/production secret_name, namespace, service_account defaults and the aws_region validation regex directly from $TF_IDENTITY_VARS"

# --- positive: the tracked aws-eks overlay fixtures render, and their
# aws.secretName/aws.region match Terraform's own values exactly ---
aws_overlay_render_staging="$root/overlay-staging-aws.yaml"
aws_overlay_render_production="$root/overlay-production-aws.yaml"
if ! "$HELM" template platform-smoke-staging-aws "$CHART" -f "$CHART/values-staging-aws.yaml" --namespace staging > "$aws_overlay_render_staging" 2>&1; then
  echo "FAIL: helm template failed for values-staging-aws.yaml" >&2
  cat "$aws_overlay_render_staging" >&2
  fail=1
fi
if ! "$HELM" template platform-smoke-production-aws "$CHART" -f "$CHART/values-production-aws.yaml" --namespace production > "$aws_overlay_render_production" 2>&1; then
  echo "FAIL: helm template failed for values-production-aws.yaml" >&2
  cat "$aws_overlay_render_production" >&2
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (aws-eks overlay renders)" >&2
  exit 1
fi
echo "OK: values-staging-aws.yaml and values-production-aws.yaml both render successfully"

overlay_remote_key() {
  awk '/^kind: ExternalSecret$/,/^---$/' "$1" | sed -n 's/^[[:space:]]*key: //p'
}
overlay_region() {
  awk '/^kind: SecretStore$/,/^---$/' "$1" | sed -n 's/^[[:space:]]*region: //p'
}

staging_overlay_key="$(overlay_remote_key "$aws_overlay_render_staging")"
production_overlay_key="$(overlay_remote_key "$aws_overlay_render_production")"
staging_overlay_region="$(overlay_region "$aws_overlay_render_staging")"
production_overlay_region="$(overlay_region "$aws_overlay_render_production")"

if [ "$staging_overlay_key" = "$tf_staging_secret_name" ]; then
  echo "OK: values-staging-aws.yaml's remoteRef.key matches terraform/envs/identity's staging_secret_name default exactly ('$tf_staging_secret_name')"
else
  echo "FAIL: values-staging-aws.yaml remoteRef.key ('$staging_overlay_key') does not match Terraform's staging_secret_name default ('$tf_staging_secret_name')" >&2
  fail=1
fi
if [ "$production_overlay_key" = "$tf_production_secret_name" ]; then
  echo "OK: values-production-aws.yaml's remoteRef.key matches terraform/envs/identity's production_secret_name default exactly ('$tf_production_secret_name')"
else
  echo "FAIL: values-production-aws.yaml remoteRef.key ('$production_overlay_key') does not match Terraform's production_secret_name default ('$tf_production_secret_name')" >&2
  fail=1
fi
# values.schema.json's own aws.region pattern is a hardcoded copy of
# Terraform's regex (JSON Schema cannot read a .tf file at Helm-lint
# time) - confirm the two literal strings still agree, so a future
# change to either side is caught here instead of silently diverging.
schema_region_pattern="$(sed -n 's/.*"pattern": "\(\^\[a-z\].*\)",$/\1/p' "$CHART/values.schema.json" | head -1)"
if [ "$schema_region_pattern" = "$tf_aws_region_regex" ]; then
  echo "OK: values.schema.json's aws.region pattern is byte-identical to Terraform's own aws_region validation regex"
else
  echo "FAIL: values.schema.json's aws.region pattern ('$schema_region_pattern') has drifted from Terraform's aws_region regex ('$tf_aws_region_regex')" >&2
  fail=1
fi
if printf '%s' "$staging_overlay_region" | grep -qE "$tf_aws_region_regex" && printf '%s' "$production_overlay_region" | grep -qE "$tf_aws_region_regex"; then
  echo "OK: both aws-eks overlays' region values match Terraform's own aws_region validation shape"
else
  echo "FAIL: an aws-eks overlay region does not match Terraform's aws_region validation shape (staging='$staging_overlay_region' production='$production_overlay_region')" >&2
  fail=1
fi

# --- positive: controller namespace/ServiceAccount Terraform defaults
# still match the real, live-verified identity (Phase 3.2/3.3
# evidence) - protects against Terraform's own defaults silently
# drifting away from the ESO release's actual namespace/ServiceAccount,
# which this chart's values never re-derive on their own. ---
if [ "$tf_staging_namespace" = "eso-staging" ] && [ "$tf_staging_service_account" = "eso-staging-external-secrets" ]; then
  echo "OK: Terraform's staging controller namespace/ServiceAccount defaults match the live-verified identity (eso-staging/eso-staging-external-secrets)"
else
  echo "FAIL: Terraform's staging controller namespace/ServiceAccount defaults changed (namespace='$tf_staging_namespace' service_account='$tf_staging_service_account') - re-verify against the live cluster before proceeding" >&2
  fail=1
fi
if [ "$tf_production_namespace" = "eso-production" ] && [ "$tf_production_service_account" = "eso-production-external-secrets" ]; then
  echo "OK: Terraform's production controller namespace/ServiceAccount defaults match the live-verified identity (eso-production/eso-production-external-secrets)"
else
  echo "FAIL: Terraform's production controller namespace/ServiceAccount defaults changed (namespace='$tf_production_namespace' service_account='$tf_production_service_account') - re-verify against the live cluster before proceeding" >&2
  fail=1
fi

# --- positive: staging and production remain fully distinct across
# every cross-validated field (same never-shared-identity bar as the
# kubernetes provider and as Terraform's own iam-policy-isolation
# tests) ---
isolation_fail=0
[ "$tf_staging_secret_name" = "$tf_production_secret_name" ] && { echo "FAIL: Terraform's staging_secret_name and production_secret_name defaults are identical" >&2; isolation_fail=1; }
[ "$tf_staging_namespace" = "$tf_production_namespace" ] && { echo "FAIL: Terraform's staging_namespace and production_namespace defaults are identical" >&2; isolation_fail=1; }
[ "$tf_staging_service_account" = "$tf_production_service_account" ] && { echo "FAIL: Terraform's staging_service_account and production_service_account defaults are identical" >&2; isolation_fail=1; }
[ "$staging_overlay_key" = "$production_overlay_key" ] && { echo "FAIL: values-staging-aws.yaml and values-production-aws.yaml resolve to the same remoteRef.key" >&2; isolation_fail=1; }
if [ "$isolation_fail" -ne 0 ]; then
  fail=1
else
  echo "OK: staging and production remain fully distinct across secret_name/namespace/service_account/remoteRef.key"
fi

# --- positive: the chart's own default (no aws-eks values file passed
# at all) never accidentally activates the aws provider - this is what
# guarantees the aws-eks profile can never activate in the current kind
# lab, where no target ever passes an *-aws.yaml file ---
default_provider_render="$root/default-provider-check.yaml"
"$HELM" template default-provider-check "$CHART" --namespace default --show-only templates/secretstore.yaml > "$default_provider_render" 2>/dev/null || true
if [ -s "$default_provider_render" ]; then
  echo "FAIL: the chart's bare defaults (no environment values file) render a SecretStore at all - externalSecret.enabled must default to false" >&2
  fail=1
else
  echo "OK: the chart's bare defaults render no SecretStore at all (externalSecret.enabled: false) - the aws-eks profile cannot activate by accident"
fi

if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (Terraform<->GitOps cross-validation)" >&2
  exit 1
fi

# --- negative (self-test of the comparison logic, not the schema):
# staging using production's secret name, and vice versa. There is no
# schema rule that could reject this - "which literal string belongs to
# which environment" is exactly what the positive cross-validation
# above checks by comparing the TRACKED fixture files against
# Terraform's own defaults. What's verified here instead is that the
# comparison itself actually catches a real mismatch when one exists -
# built as a standalone render (not layered on values-staging.yaml,
# whose real kubernetes-only fields would trip the aws mutual-exclusion
# rules for an unrelated reason and mask what this case means to test),
# using Terraform's OWN production_secret_name default rather than a
# hand-typed duplicate, so this can never silently stop testing the
# real swap. ---
swapped_fixture="$root/swapped-secret-name.yaml"
aws_fixture "staging-claiming-production-secret" "staging-aws-backend" "us-east-1" "$tf_production_secret_name" > "$swapped_fixture"
swapped_render="$root/swapped-secret-name-render.yaml"
if ! "$HELM" template swap-check "$CHART" -f "$swapped_fixture" --namespace staging > "$swapped_render" 2>&1; then
  echo "FAIL: the swapped-secret-name self-test fixture failed to render at all (expected: renders, but with the wrong content)" >&2
  fail=1
else
  swapped_key="$(overlay_remote_key "$swapped_render")"
  if [ "$swapped_key" = "$tf_staging_secret_name" ]; then
    echo "FAIL: the swapped-secret-name self-test did not actually swap anything - the comparison logic above cannot be trusted" >&2
    fail=1
  elif [ "$swapped_key" = "$tf_production_secret_name" ]; then
    echo "OK: confirmed the staging/production secret-name comparison logic correctly distinguishes a genuine swap (a staging overlay carrying production's secret name resolves to production's name, not staging's, exactly as the positive check above would catch if it happened in the tracked file)"
  else
    echo "FAIL: swapped-secret-name self-test produced an unexpected key '$swapped_key'" >&2
    fail=1
  fi
fi

run_negative_case_aws "aws provider with an empty region" 'externalSecret:
  enabled: true
  provider: "aws"
  secretStoreName: "x"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    region: ""
    secretName: "x"'

run_negative_case_aws "aws provider with an invalid (non-region-shaped) region" 'externalSecret:
  enabled: true
  provider: "aws"
  secretStoreName: "x"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    region: "not-a-region"
    secretName: "x"'

run_negative_case_aws "aws provider remote key is an ARN, not a logical name" 'externalSecret:
  enabled: true
  provider: "aws"
  secretStoreName: "x"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288
  aws:
    region: "us-east-1"
    secretName: "arn:aws:secretsmanager:us-east-1:aws:secret:eks-gitops-platform-project/staging/backend"'

if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED"
  exit 1
fi
echo "check-standard-workload-chart: OK"
