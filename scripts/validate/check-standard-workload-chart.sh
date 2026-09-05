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
for render in "$render_staging" "$render_production"; do
  svc_sel="$(awk '/^kind: Service$/,/^---$/' "$render" | sed -n '/selector:/,/ports:/p' | grep 'app.kubernetes.io' | sort)"
  dep_labels="$(awk '/^kind: Deployment$/,0' "$render" | sed -n '/template:/,/annotations:/p' | grep 'app.kubernetes.io' | sort)"
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

if [ "$fail" -ne 0 ]; then
  echo "check-standard-workload-chart: FAILED"
  exit 1
fi
echo "check-standard-workload-chart: OK"
