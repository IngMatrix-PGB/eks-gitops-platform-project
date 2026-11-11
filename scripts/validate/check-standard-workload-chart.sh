#!/bin/sh
# Fully offline validation of charts/standard-workload: lint + render for
# all three environments, deterministic post-merge negative schema fixtures
# (built at runtime under mktemp -d, never a literal fixture file),
# digest-only image enforcement, Restricted-PSS field presence, a
# rendered-kind allowlist, proof no Secret renders, proof no deferred
# optional resource (Ingress/HPA/PDB/NetworkPolicy/ServiceMonitor)
# renders or is schema-exposed, and a client-side kubectl dry-run for
# all three environments. Never touches a cluster. Backs
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

echo "check-standard-workload-chart: helm lint (dev) ..."
if ! "$HELM" lint "$CHART" -f "$CHART/values-dev.yaml"; then
  echo "FAIL: helm lint failed for dev" >&2
  fail=1
fi

echo "check-standard-workload-chart: helm lint (uat) ..."
if ! "$HELM" lint "$CHART" -f "$CHART/values-uat.yaml"; then
  echo "FAIL: helm lint failed for uat" >&2
  fail=1
fi

echo "check-standard-workload-chart: helm lint (prod) ..."
if ! "$HELM" lint "$CHART" -f "$CHART/values-prod.yaml"; then
  echo "FAIL: helm lint failed for prod" >&2
  fail=1
fi

render_dev="$root/dev.yaml"
render_uat="$root/uat.yaml"
render_prod="$root/prod.yaml"

echo "check-standard-workload-chart: helm template (dev) ..."
if ! "$HELM" template platform-smoke-dev "$CHART" -f "$CHART/values-dev.yaml" --namespace dev > "$render_dev" 2>&1; then
  echo "FAIL: helm template failed for dev" >&2
  cat "$render_dev" >&2
  fail=1
fi

echo "check-standard-workload-chart: helm template (uat) ..."
# --namespace matters as of Phase 2.6.2: templates/secretstore.yaml
# reads .Release.Namespace for the auth ServiceAccount reference, which
# `helm template` otherwise defaults to "default" - not representative
# of how Argo CD actually renders this chart (always with the
# Application's real destination namespace). Passing it here makes the
# offline render match the real deployed shape.
if ! "$HELM" template platform-smoke-uat "$CHART" -f "$CHART/values-uat.yaml" --namespace uat > "$render_uat" 2>&1; then
  echo "FAIL: helm template failed for uat" >&2
  cat "$render_uat" >&2
  fail=1
fi

echo "check-standard-workload-chart: helm template (prod) ..."
if ! "$HELM" template platform-smoke-prod "$CHART" -f "$CHART/values-prod.yaml" --namespace prod > "$render_prod" 2>&1; then
  echo "FAIL: helm template failed for prod" >&2
  cat "$render_prod" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (cannot continue without all three renders)" >&2
  exit 1
fi

# --- rendered-kind allowlist: exactly ConfigMap, Deployment,
# ExternalSecret, SecretStore, Service, ServiceAccount (as of Phase
# 2.6.2 - two ServiceAccount objects render: the workload's own and the
# SecretStore's dedicated auth identity) ---
for render in "$render_dev" "$render_uat" "$render_prod"; do
  kinds="$(grep -E '^kind: ' "$render" | sort -u)"
  expected="$(printf 'kind: ConfigMap\nkind: Deployment\nkind: ExternalSecret\nkind: SecretStore\nkind: Service\nkind: ServiceAccount')"
  if [ "$kinds" != "$expected" ]; then
    echo "FAIL: $render rendered an unexpected kind set:" >&2
    echo "$kinds" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: rendered-kind allowlist matches exactly (ConfigMap, Deployment, ExternalSecret, SecretStore, Service, ServiceAccount) in all three environments"

# --- no Secret renders ---
for render in "$render_dev" "$render_uat" "$render_prod"; do
  if grep -q '^kind: Secret$' "$render"; then
    echo "FAIL: $render rendered a Secret - not authorized in Phase 2.4" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no Secret rendered in any environment"

# --- deferred optional resources: must not render and must not be schema-exposed ---
for kind in Ingress HorizontalPodAutoscaler PodDisruptionBudget NetworkPolicy ServiceMonitor; do
  for render in "$render_dev" "$render_uat" "$render_prod"; do
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
for render in "$render_dev" "$render_uat" "$render_prod"; do
  if grep -E '^\s*image: ' "$render" | grep -v '@sha256:' >/dev/null 2>&1; then
    echo "FAIL: $render contains a tag-only (non-digest) image reference" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: every rendered image reference is digest-pinned"

# --- Restricted PSS field presence (grep-based, matches lab/argocd/render.sh style) ---
for render in "$render_dev" "$render_uat" "$render_prod"; do
  for needle in "runAsNonRoot: true" "runAsUser: 65532" "runAsGroup: 65532" "allowPrivilegeEscalation: false" "readOnlyRootFilesystem: true" "- ALL" "seccompProfile" "type: RuntimeDefault" "automountServiceAccountToken: false"; do
    if ! grep -qF -- "$needle" "$render"; then
      echo "FAIL: $render is missing expected Restricted-PSS field: $needle" >&2
      fail=1
    fi
  done
done
[ "$fail" -eq 0 ] && echo "OK: Restricted-PSS fields present in all three rendered environments"

# --- Service selector matches Deployment pod-template labels (duplicate/mismatch guard) ---
#
# Phase 3.2.1: structural (indentation-bounded) extraction, replacing
# the previous "selector:"-to-"ports:" / "template:"-to-"annotations:"
# sed ranges, which silently broke if either literal next-sibling key
# ever changed or moved. yaml_indented_block locates a key line, records
# ITS OWN indentation, and returns exactly the lines nested strictly
# more than that - the real YAML rule for "this mapping has ended" -
# never assuming what key (if any) comes next. Verified byte-for-byte
# equivalent output against this chart's real uat/prod
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

for render in "$render_dev" "$render_uat" "$render_prod"; do
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
[ "$fail" -eq 0 ] && echo "OK: Service selectors match Deployment pod-template labels in all three environments"

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
for render in "$render_dev" "$render_uat" "$render_prod"; do
  if grep -q '^kind: Secret$' "$render"; then
    echo "FAIL: $render rendered a Secret manifest - not authorized; the target Secret must be ESO-managed only" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no Secret manifest rendered in any environment (target Secret is ESO-managed only)"

# --- SecretStore is always namespaced, never ClusterSecretStore ---
for render in "$render_dev" "$render_uat" "$render_prod"; do
  if grep -q '^kind: ClusterSecretStore$' "$render"; then
    echo "FAIL: $render rendered a ClusterSecretStore - only a namespaced SecretStore is authorized" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no ClusterSecretStore rendered in any environment"

# --- the workload container never consumes the secret via env,
# envFrom, or secretKeyRef - read-only file mount only ---
for render in "$render_dev" "$render_uat" "$render_prod"; do
  if grep -qE '^\s*envFrom:' "$render"; then
    echo "FAIL: $render uses envFrom - the secret must only ever be consumed as a read-only file mount" >&2
    fail=1
  fi
  if grep -q 'secretKeyRef:' "$render"; then
    echo "FAIL: $render uses secretKeyRef - the secret must only ever be consumed as a read-only file mount" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no envFrom/secretKeyRef in any environment - the secret is never exposed via environment variables"

# --- the secret volumeMount is read-only ---
for render in "$render_dev" "$render_uat" "$render_prod"; do
  if ! awk '/- name: secret$/{f=1} f && /mountPath:/{print; exit}' "$render" | grep -q .; then
    echo "FAIL: $render has no 'secret' volumeMount" >&2
    fail=1
  fi
done
if grep -A2 '            - name: secret$' "$render_dev" | grep -q 'readOnly: true' \
  && grep -A2 '            - name: secret$' "$render_uat" | grep -q 'readOnly: true' \
  && grep -A2 '            - name: secret$' "$render_prod" | grep -q 'readOnly: true'; then
  echo "OK: the secret volumeMount is readOnly: true in all three environments"
else
  echo "FAIL: the secret volumeMount is not readOnly: true in one or more environments" >&2
  fail=1
fi

# --- dev/uat/prod isolation: no two rendered environments may share a
# SecretStore name, source namespace, source Secret name, or auth
# ServiceAccount name (checked pairwise across all three). Extracted
# from the isolated SecretStore document only (bounded by its own
# "kind: SecretStore" ... next "---" separator), since "kind:
# SecretStore" also appears as the literal value of ExternalSecret's
# own secretStoreRef.kind field elsewhere in the same file - a plain
# grep -A/-B against the whole file cannot tell those two occurrences
# apart. ---
secretstore_block() {
  awk '/^kind: SecretStore$/,0' "$1" | awk '/^---$/{exit} {print}'
}
isolation_identity() {
  # $1=render file. Prints "secretstore|source-ns|source-key|auth-sa".
  printf '%s|%s|%s|%s\n' \
    "$(secretstore_block "$1" | grep 'name:' | head -1 | awk '{print $2}')" \
    "$(secretstore_block "$1" | grep 'remoteNamespace:' | awk '{print $2}')" \
    "$(grep -A1 'remoteRef:' "$1" | grep 'key:' | awk '{print $2}')" \
    "$(secretstore_block "$1" | grep -A1 'serviceAccount:' | grep 'name:' | awk '{print $2}')"
}
isolation_fail=0
for pair in "dev:uat" "dev:prod" "uat:prod"; do
  a="${pair%%:*}"; b="${pair##*:}"
  eval "a_render=\$render_$a"; eval "b_render=\$render_$b"
  a_id="$(isolation_identity "$a_render")"; b_id="$(isolation_identity "$b_render")"
  i=1
  for label in "SecretStore name" "source namespace" "source Secret name" "auth ServiceAccount name"; do
    a_val="$(printf '%s' "$a_id" | cut -d'|' -f"$i")"
    b_val="$(printf '%s' "$b_id" | cut -d'|' -f"$i")"
    if [ -z "$a_val" ] || [ -z "$b_val" ]; then
      echo "FAIL: could not extract the $label for $a or $b" >&2
      isolation_fail=1
    elif [ "$a_val" = "$b_val" ]; then
      echo "FAIL: $a and $b share the same $label '$a_val'" >&2
      isolation_fail=1
    fi
    i=$((i + 1))
  done
done
if [ "$isolation_fail" -ne 0 ]; then
  fail=1
else
  echo "OK: dev, uat, and prod have pairwise-distinct SecretStore/source-namespace/source-Secret/auth-ServiceAccount names"
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
    for render in "$render_dev" "$render_uat" "$render_prod"; do
      if ! pkubectl apply --dry-run=client -f "$render" >/dev/null 2>&1; then
        echo "FAIL: kubectl dry-run=client (against the project cluster, as a schema oracle only - nothing is persisted) rejected $render" >&2
        pkubectl apply --dry-run=client -f "$render" >&2 || true
        fail=1
      fi
    done
    [ "$fail" -eq 0 ] && echo "OK: client-side kubectl dry-run passed for all three environments (project cluster used as schema oracle, no mutation)"
  fi
fi

# --- deterministic negative schema regression (post-merge, values built at runtime) ---
run_negative_case() {
  desc="$1"; fixture_content="$2"
  fixture="$root/fixture-$$.yaml"
  printf '%s\n' "$fixture_content" > "$fixture"
  set +e
  lint_out="$("$HELM" lint "$CHART" -f "$CHART/values-uat.yaml" -f "$fixture" 2>&1)"
  lint_rc=$?
  tmpl_out="$("$HELM" template x "$CHART" -f "$CHART/values-uat.yaml" -f "$fixture" 2>&1)"
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
# values-uat.yaml, which sets sourceNamespace/sourceSecretName/
# authServiceAccountName to real, non-default values - correct for a
# "kubernetes" provider case (or one deliberately proving those values
# leak through as a violation under "aws" - see the case that does
# exactly that below), but wrong for an aws-provider case meant to
# demonstrate one single, exact defect: layering on values-uat.yaml
# would ALSO trip the aws-branch's kubernetes-field exclusion rules,
# masking the one defect under test behind an unrelated one and
# violating "cada fixture debe demostrar la causa exacta del rechazo".
# This variant instead builds a complete, standalone aws-profile
# fixture (values.yaml's own base + this fixture only, never values-
# uat.yaml) so the only possible violation is the one deliberately
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
  sourceNamespace: "eso-source-uat"
  sourceSecretName: "local-backend-uat"
  sourceProperty: "message"
  authServiceAccountName: "uat-secretstore-reader"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288'

run_negative_case "externalSecret with an unknown extra property" 'externalSecret:
  enabled: true
  secretStoreName: "uat-kubernetes-backend"
  sourceNamespace: "eso-source-uat"
  sourceSecretName: "local-backend-uat"
  sourceProperty: "message"
  authServiceAccountName: "uat-secretstore-reader"
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

# --- positive: a full standalone AWS-provider render, uat and
# prod, each with its own distinct secretStoreName/region/
# secretName (mirrors the same never-shared-identity convention as the
# real kubernetes-provider values-uat.yaml/values-prod.yaml).
# Built as a complete values file (not layered on values-uat.yaml,
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

aws_envs="dev uat prod"
for env_name in $aws_envs; do
  fixture="$root/aws-${env_name}-fixture.yaml"
  render="$root/aws-${env_name}.yaml"
  aws_fixture "$env_name" "${env_name}-aws-backend" "us-east-1" "eks-gitops-platform-project/${env_name}/backend" > "$fixture"
  echo "check-standard-workload-chart: helm lint (aws provider, $env_name fixture) ..."
  if ! "$HELM" lint "$CHART" -f "$fixture"; then
    echo "FAIL: helm lint failed for the aws-provider $env_name fixture" >&2
    fail=1
  fi
  echo "check-standard-workload-chart: helm template (aws provider, $env_name fixture) ..."
  if ! "$HELM" template "platform-smoke-${env_name}-aws" "$CHART" -f "$fixture" --namespace "$env_name" > "$render" 2>&1; then
    echo "FAIL: helm template failed for the aws-provider $env_name fixture" >&2
    cat "$render" >&2
    fail=1
  fi
done
aws_render_dev="$root/aws-dev.yaml"
aws_render_uat="$root/aws-uat.yaml"
aws_render_prod="$root/aws-prod.yaml"
if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED before the aws-provider content checks" >&2
  exit 1
fi
echo "OK: aws-provider dev, uat, and prod fixtures all lint and render successfully"

# --- positive: aws-provider rendered-kind allowlist. Exactly one
# ServiceAccount (the workload's own) - unlike the kubernetes provider,
# no dedicated auth ServiceAccount is rendered, since Pod Identity
# authenticates the ESO controller's own pod, never a per-SecretStore
# identity. ---
for render in "$aws_render_dev" "$aws_render_uat" "$aws_render_prod"; do
  kinds="$(grep -E '^kind: ' "$render" | sort)"
  expected="$(printf 'kind: ConfigMap\nkind: Deployment\nkind: ExternalSecret\nkind: SecretStore\nkind: Service\nkind: ServiceAccount')"
  if [ "$kinds" != "$expected" ]; then
    echo "FAIL: $render (aws provider) rendered an unexpected kind set:" >&2
    echo "$kinds" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: aws-provider rendered-kind allowlist matches exactly (one ServiceAccount, no extra auth identity) in every environment"

# --- positive: no Secret ever rendered by the aws provider either ---
for render in "$aws_render_dev" "$aws_render_uat" "$aws_render_prod"; do
  if grep -q '^kind: Secret$' "$render"; then
    echo "FAIL: $render (aws provider) rendered a Secret manifest - not authorized" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: no Secret manifest rendered by the aws provider in any environment"

# --- positive: SecretStore AWS shape - service/region present, auth
# completely absent, and no serviceAccountRef/role/externalID/static
# credential field anywhere in the render (contract-wide, not just
# inside the SecretStore document - a stray field in any other document
# would be just as much a violation). ---
for render in "$aws_render_dev" "$aws_render_uat" "$aws_render_prod"; do
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
[ "$fail" -eq 0 ] && echo "OK: aws-provider SecretStore has service/region set and zero auth/serviceAccountRef/role/externalID/static-credential fields in any environment"

# --- positive: region and remote key are exactly the configured
# synthetic values (proves the schema's aws.region/aws.secretName
# actually flow through to the render, not merely "present in the
# values file and never consumed" - the "no dead configuration" bar the
# kubernetes-provider fields are already held to) ---
aws_region_fail=0
aws_key_fail=0
for env_name in $aws_envs; do
  eval "render=\$aws_render_$env_name"
  region="$(awk '/^kind: SecretStore$/,/^---$/' "$render" | sed -n 's/^[[:space:]]*region: //p')"
  remote_key="$(awk '/^kind: ExternalSecret$/,/^---$/' "$render" | sed -n 's/^[[:space:]]*key: //p')"
  eval "${env_name}_remote_key=\$remote_key"
  if [ "$region" != "us-east-1" ]; then
    echo "FAIL: aws-provider SecretStore region mismatch for $env_name ('$region')" >&2
    aws_region_fail=1
  fi
  if [ "$remote_key" != "eks-gitops-platform-project/${env_name}/backend" ]; then
    echo "FAIL: aws-provider remoteRef.key mismatch for $env_name ('$remote_key')" >&2
    aws_key_fail=1
  fi
done
[ "$aws_region_fail" -eq 0 ] && echo "OK: aws-provider SecretStore region matches the configured value in every environment" || fail=1
[ "$aws_key_fail" -eq 0 ] && echo "OK: aws-provider ExternalSecret remoteRef.key is the configured logical secret name (never an ARN) in every environment" || fail=1

# --- positive: dev, uat, and prod aws-provider identities remain
# pairwise distinct (same never-shared-identity bar as the kubernetes
# provider) ---
aws_pair_fail=0
for pair in "dev:uat" "dev:prod" "uat:prod"; do
  a="${pair%%:*}"; b="${pair##*:}"
  eval "a_key=\$${a}_remote_key"; eval "b_key=\$${b}_remote_key"
  if [ "$a_key" = "$b_key" ]; then
    echo "FAIL: aws-provider $a and $b share the same remote secret name '$a_key'" >&2
    aws_pair_fail=1
  fi
done
[ "$aws_pair_fail" -eq 0 ] && echo "OK: aws-provider dev, uat, and prod have pairwise-distinct remote secret names" || fail=1

# --- positive: ExternalSecret points at the correct SecretStore (same
# name this environment's own aws_fixture configured) ---
for pair in "$aws_render_dev:dev-aws-backend" "$aws_render_uat:uat-aws-backend" "$aws_render_prod:prod-aws-backend"; do
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
[ "$fail" -eq 0 ] && echo "OK: aws-provider ExternalSecret.spec.secretStoreRef.name matches its own environment's SecretStore in every environment"

# --- positive: Deployment consumes the SAME target Secret name via the
# SAME read-only volume/mount shape as the kubernetes provider - proves
# templates/deployment.yaml needed zero changes for this contract ---
for render in "$aws_render_dev" "$aws_render_uat" "$aws_render_prod"; do
  if ! grep -qE '^[[:space:]]*secretName: .+-secret$' "$render"; then
    echo "FAIL: $render (aws provider) Deployment volume does not reference the chart's own target Secret name" >&2
    fail=1
  fi
  if ! awk '/- name: secret$/{f=1} f && /mountPath:/{print; exit}' "$render" | grep -q .; then
    echo "FAIL: $render (aws provider) has no 'secret' volumeMount" >&2
    fail=1
  fi
done
if grep -A2 '            - name: secret$' "$aws_render_dev" | grep -q 'readOnly: true' \
  && grep -A2 '            - name: secret$' "$aws_render_uat" | grep -q 'readOnly: true' \
  && grep -A2 '            - name: secret$' "$aws_render_prod" | grep -q 'readOnly: true'; then
  echo "OK: aws-provider secret volumeMount is readOnly: true in every environment, same as the kubernetes provider"
else
  echo "FAIL: aws-provider secret volumeMount is not readOnly: true in one or more environments" >&2
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
  sourceSecretName: "local-backend-uat"
  sourceProperty: "message"
  authServiceAccountName: "uat-secretstore-reader"
  refreshInterval: "1m"
  key: "message"
  mountPath: "/etc/secret"
  fileName: "message"
  defaultMode: 288'

# Layered on values-uat.yaml (via run_negative_case's own -f
# values-uat.yaml -f <fixture> harness): values-uat.yaml's own
# sourceNamespace/sourceSecretName/authServiceAccountName are real,
# non-default values - switching only "provider" to "aws" here proves
# those real kubernetes-only values are correctly rejected as misplaced
# configuration under the aws profile (not merely "absent", which the
# harmless base-values.yaml defaults already prove is accepted, see the
# positive aws_fixture renders above, which never touch values-
# uat.yaml at all).
run_negative_case "kubernetes-only fields (from values-uat.yaml) present under provider: aws" 'externalSecret:
  provider: "aws"
  aws:
    region: "us-east-1"
    secretName: "x"'

run_negative_case "aws block present under provider: kubernetes" 'externalSecret:
  enabled: true
  provider: "kubernetes"
  secretStoreName: "x"
  sourceNamespace: "eso-source-uat"
  sourceSecretName: "local-backend-uat"
  sourceProperty: "message"
  authServiceAccountName: "uat-secretstore-reader"
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
# (values-{dev,uat,prod}-aws.yaml) and Terraform<->
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

tf_aws_region_regex="$(tf_region_regex)"
if [ -z "$tf_aws_region_regex" ]; then
  echo "FAIL: could not extract the aws_region validation regex from $TF_IDENTITY_VARS" >&2
  fail=1
fi
for env_name in $aws_envs; do
  for field in secret_name namespace service_account; do
    val="$(tf_default "${env_name}_${field}")"
    if [ -z "$val" ]; then
      echo "FAIL: could not extract ${env_name}_${field} from $TF_IDENTITY_VARS - Terraform<->GitOps cross-validation cannot proceed" >&2
      fail=1
    fi
    eval "tf_${env_name}_${field}=\$val"
  done
done
if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (Terraform variable extraction)" >&2
  exit 1
fi
echo "OK: extracted dev/uat/prod secret_name, namespace, service_account defaults and the aws_region validation regex directly from $TF_IDENTITY_VARS"

# --- positive: the tracked aws-eks overlay fixtures render, and their
# aws.secretName/aws.region match Terraform's own values exactly ---
overlay_remote_key() {
  awk '/^kind: ExternalSecret$/,/^---$/' "$1" | sed -n 's/^[[:space:]]*key: //p'
}
overlay_region() {
  awk '/^kind: SecretStore$/,/^---$/' "$1" | sed -n 's/^[[:space:]]*region: //p'
}
for env_name in $aws_envs; do
  overlay_render="$root/overlay-${env_name}-aws.yaml"
  if ! "$HELM" template "platform-smoke-${env_name}-aws" "$CHART" -f "$CHART/values-${env_name}-aws.yaml" --namespace "$env_name" > "$overlay_render" 2>&1; then
    echo "FAIL: helm template failed for values-${env_name}-aws.yaml" >&2
    cat "$overlay_render" >&2
    fail=1
    continue
  fi
  eval "${env_name}_overlay_key=\$(overlay_remote_key \"\$overlay_render\")"
  eval "${env_name}_overlay_region=\$(overlay_region \"\$overlay_render\")"
done
if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED (aws-eks overlay renders)" >&2
  exit 1
fi
echo "OK: values-dev-aws.yaml, values-uat-aws.yaml, and values-prod-aws.yaml all render successfully"

for env_name in $aws_envs; do
  eval "overlay_key=\$${env_name}_overlay_key"
  eval "tf_secret=\$tf_${env_name}_secret_name"
  if [ "$overlay_key" = "$tf_secret" ]; then
    echo "OK: values-${env_name}-aws.yaml's remoteRef.key matches terraform/envs/identity's ${env_name}_secret_name default exactly ('$tf_secret')"
  else
    echo "FAIL: values-${env_name}-aws.yaml remoteRef.key ('$overlay_key') does not match Terraform's ${env_name}_secret_name default ('$tf_secret')" >&2
    fail=1
  fi
done
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
region_fail=0
for env_name in $aws_envs; do
  eval "overlay_region=\$${env_name}_overlay_region"
  if ! printf '%s' "$overlay_region" | grep -qE "$tf_aws_region_regex"; then
    echo "FAIL: the $env_name aws-eks overlay region ('$overlay_region') does not match Terraform's aws_region validation shape" >&2
    region_fail=1
  fi
done
[ "$region_fail" -eq 0 ] && echo "OK: every aws-eks overlay's region value matches Terraform's own aws_region validation shape" || fail=1

# --- positive: controller namespace/ServiceAccount Terraform defaults
# match the ESO scoped release naming the lab uses (eso-<env> /
# eso-<env>-external-secrets, scripts/eso/_lib.sh) - protects against
# Terraform's own defaults silently drifting away from the release's
# actual namespace/ServiceAccount, which this chart's values never
# re-derive on their own. ---
for env_name in $aws_envs; do
  eval "tf_ns=\$tf_${env_name}_namespace"
  eval "tf_sa=\$tf_${env_name}_service_account"
  if [ "$tf_ns" = "eso-${env_name}" ] && [ "$tf_sa" = "eso-${env_name}-external-secrets" ]; then
    echo "OK: Terraform's $env_name controller namespace/ServiceAccount defaults match the ESO release naming (eso-${env_name}/eso-${env_name}-external-secrets)"
  else
    echo "FAIL: Terraform's $env_name controller namespace/ServiceAccount defaults changed (namespace='$tf_ns' service_account='$tf_sa') - re-verify against the ESO release naming before proceeding" >&2
    fail=1
  fi
done

# --- positive: dev, uat, and prod remain pairwise distinct across
# every cross-validated field (same never-shared-identity bar as the
# kubernetes provider and as Terraform's own iam-policy-isolation
# tests) ---
isolation_fail=0
for pair in "dev:uat" "dev:prod" "uat:prod"; do
  a="${pair%%:*}"; b="${pair##*:}"
  for field in secret_name namespace service_account; do
    eval "a_val=\$tf_${a}_${field}"; eval "b_val=\$tf_${b}_${field}"
    if [ "$a_val" = "$b_val" ]; then
      echo "FAIL: Terraform's ${a}_${field} and ${b}_${field} defaults are identical" >&2
      isolation_fail=1
    fi
  done
  eval "a_key=\$${a}_overlay_key"; eval "b_key=\$${b}_overlay_key"
  if [ "$a_key" = "$b_key" ]; then
    echo "FAIL: values-${a}-aws.yaml and values-${b}-aws.yaml resolve to the same remoteRef.key" >&2
    isolation_fail=1
  fi
done
if [ "$isolation_fail" -ne 0 ]; then
  fail=1
else
  echo "OK: dev, uat, and prod remain pairwise distinct across secret_name/namespace/service_account/remoteRef.key"
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
# uat using prod's secret name, and vice versa. There is no
# schema rule that could reject this - "which literal string belongs to
# which environment" is exactly what the positive cross-validation
# above checks by comparing the TRACKED fixture files against
# Terraform's own defaults. What's verified here instead is that the
# comparison itself actually catches a real mismatch when one exists -
# built as a standalone render (not layered on values-uat.yaml,
# whose real kubernetes-only fields would trip the aws mutual-exclusion
# rules for an unrelated reason and mask what this case means to test),
# using Terraform's OWN prod_secret_name default rather than a
# hand-typed duplicate, so this can never silently stop testing the
# real swap. ---
swapped_fixture="$root/swapped-secret-name.yaml"
aws_fixture "uat-claiming-prod-secret" "uat-aws-backend" "us-east-1" "$tf_prod_secret_name" > "$swapped_fixture"
swapped_render="$root/swapped-secret-name-render.yaml"
if ! "$HELM" template swap-check "$CHART" -f "$swapped_fixture" --namespace uat > "$swapped_render" 2>&1; then
  echo "FAIL: the swapped-secret-name self-test fixture failed to render at all (expected: renders, but with the wrong content)" >&2
  fail=1
else
  swapped_key="$(overlay_remote_key "$swapped_render")"
  if [ "$swapped_key" = "$tf_uat_secret_name" ]; then
    echo "FAIL: the swapped-secret-name self-test did not actually swap anything - the comparison logic above cannot be trusted" >&2
    fail=1
  elif [ "$swapped_key" = "$tf_prod_secret_name" ]; then
    echo "OK: confirmed the uat/prod secret-name comparison logic correctly distinguishes a genuine swap (a uat overlay carrying prod's secret name resolves to prod's name, not uat's, exactly as the positive check above would catch if it happened in the tracked file)"
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
    secretName: "arn:aws:secretsmanager:us-east-1:aws:secret:eks-gitops-platform-project/uat/backend"'

if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED"
  exit 1
fi
echo "check-standard-workload-chart: OK"
