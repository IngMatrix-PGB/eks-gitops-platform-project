#!/bin/sh
# Fully offline Helm render of gitops/bootstrap, plus proof that it
# renders exactly the authorized shape: one AppProject, one
# ApplicationSet with exactly two generator elements, zero Secrets, no
# wildcard permissions, and correct revision propagation. Never touches
# the cluster. Backs `make gitops-render`. Accepts REVISION=<value>
# (default main) to prove propagation for a non-default revision too.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh
# shellcheck source=../../scripts/gitops/_lib.sh
. scripts/gitops/_lib.sh
require_helm

revision="${REVISION:-$GITOPS_DEFAULT_REVISION}"

echo "gitops-render: helm lint ..."
if ! "$HELM_BIN" lint gitops/bootstrap; then
  echo "FAIL: helm lint failed" >&2
  exit 1
fi
echo "OK: helm lint passed"

render_out="$(mktemp)"
cleanup() { rm -f "$render_out"; }
trap cleanup EXIT INT TERM

echo "gitops-render: rendering with gitRevision=${revision} ..."
if ! "$HELM_BIN" template gitops/bootstrap --set "gitRevision=${revision}" > "$render_out" 2>&1; then
  echo "FAIL: helm template failed" >&2
  cat "$render_out" >&2
  exit 1
fi

fail=0

appproject_count="$(grep -c '^kind: AppProject$' "$render_out" || true)"
if [ "$appproject_count" != "1" ]; then
  echo "FAIL: expected exactly 1 AppProject, found $appproject_count" >&2
  fail=1
else
  echo "OK: exactly 1 AppProject rendered"
fi

appset_count="$(grep -c '^kind: ApplicationSet$' "$render_out" || true)"
if [ "$appset_count" != "1" ]; then
  echo "FAIL: expected exactly 1 ApplicationSet, found $appset_count" >&2
  fail=1
else
  echo "OK: exactly 1 ApplicationSet rendered"
fi

secret_count="$(grep -c '^kind: Secret$' "$render_out" || true)"
if [ "$secret_count" != "0" ]; then
  echo "FAIL: expected 0 Secrets rendered, found $secret_count" >&2
  fail=1
else
  echo "OK: no Secret rendered"
fi

generator_elements="$(grep -c '^\s*- env: ' "$render_out" || true)"
if [ "$generator_elements" != "2" ]; then
  echo "FAIL: expected exactly 2 generator list elements, found $generator_elements" >&2
  fail=1
else
  echo "OK: exactly 2 generator elements (staging, production)"
fi

if grep -qE 'sourceRepos:\s*$' "$render_out" && grep -A1 'sourceRepos:' "$render_out" | grep -q '"\*"'; then
  echo "FAIL: wildcard sourceRepos detected" >&2
  fail=1
fi
if grep -qE 'namespace: "\*"|server: "\*"' "$render_out"; then
  echo "FAIL: wildcard destination detected" >&2
  fail=1
fi
if [ "$fail" -eq 0 ]; then
  echo "OK: no wildcard source/destination permissions found"
fi

if grep -q "targetRevision: ${revision}" "$render_out"; then
  echo "OK: revision '${revision}' propagated into the generated-Application template"
else
  echo "FAIL: revision '${revision}' not found in rendered targetRevision" >&2
  fail=1
fi

# =============================================================================
# Phase 3.3.4a: aws-eks profile (DESIGNED / NOT DEPLOYED / STATICALLY
# VALIDATED offline only). templates/applicationset.yaml's generator is
# profile-exclusive - exactly one of local-kind/aws-eks ever executes,
# never both, and any other value fails the render closed (Helm's
# `fail`). Nothing below ever contacts a cluster or AWS.
# =============================================================================

# --- positive: the default render (this script's own $render_out
# above, no --set profile=) never activates aws-eks by omission. Only
# the ApplicationSet's own generator "- env: " lines matter here - the
# AppProject's destination whitelist legitimately contains the
# staging-aws/production-aws namespace strings always (a static
# allow-list, never profile-gated - see templates/appproject.yaml's own
# comment), so checking for those strings anywhere in the render would
# be a false positive, not a real "AWS activated" signal. ---
if grep -qE '^\s*- env: (staging-aws|production-aws)$' "$render_out"; then
  echo "FAIL: the default render (no profile set) already generates an aws-eks Application - AWS must never activate by omission" >&2
  fail=1
else
  echo "OK: the default render (profile unset) generates zero aws-eks Applications - AWS cannot activate by omission"
fi
if grep -qiE '^kind: SecretStore$|^kind: Secret$|auth:|serviceAccountRef|arn:aws:|AKIA[0-9A-Z]{16}' "$render_out"; then
  echo "FAIL: the default render contains a SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped string - this chart must never render workload-level resources at all" >&2
  fail=1
else
  echo "OK: the default render contains zero SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped content (this chart only ever renders AppProject/ApplicationSet, never workload resources, for either profile)"
fi

# --- positive: AppProject's destination whitelist keeps both existing
# local namespaces exactly as before, plus exactly the 2 aws-eks
# namespaces added, never a wildcard - scoped to the AppProject
# document only (kind: AppProject to the next "kind:" line), since the
# ApplicationSet's own generator elements further down the same render
# also contain "namespace: staging"/"namespace: production" lines that
# must not be double-counted as AppProject destinations. ---
appproject_doc="$(awk '/^kind: AppProject$/{f=1} f && /^kind: ApplicationSet$/{exit} f{print}' "$render_out")"
local_dest_count="$(printf '%s\n' "$appproject_doc" | grep -cE 'namespace: (staging|production)$' || true)"
aws_dest_count="$(printf '%s\n' "$appproject_doc" | grep -cE 'namespace: (staging-aws|production-aws)$' || true)"
if [ "$local_dest_count" = "2" ] && [ "$aws_dest_count" = "2" ]; then
  echo "OK: AppProject destinations are exactly the 2 existing local namespaces (staging, production) plus exactly the 2 aws-eks namespaces (staging-aws, production-aws) - none removed, none wildcarded"
else
  echo "FAIL: AppProject destination count unexpected (local=$local_dest_count, expected 2; aws=$aws_dest_count, expected 2)" >&2
  fail=1
fi

# --- positive: profile=aws-eks renders exactly 2 Applications, named
# and namespaced exactly as the addendum specifies - never invented ---
echo "gitops-render: helm lint (profile=aws-eks) ..."
if ! "$HELM_BIN" lint gitops/bootstrap --set profile=aws-eks; then
  echo "FAIL: helm lint failed for profile=aws-eks" >&2
  fail=1
fi
aws_render_out="$(mktemp)"
trap 'rm -f "$render_out" "$aws_render_out"' EXIT INT TERM
echo "gitops-render: rendering profile=aws-eks ..."
if ! "$HELM_BIN" template gitops/bootstrap --set profile=aws-eks > "$aws_render_out" 2>&1; then
  echo "FAIL: helm template failed for profile=aws-eks" >&2
  cat "$aws_render_out" >&2
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "gitops-render: FAILED (aws-eks profile render)" >&2
  exit 1
fi

aws_generator_elements="$(grep -cE '^\s*- env: ' "$aws_render_out" || true)"
if [ "$aws_generator_elements" != "2" ]; then
  echo "FAIL: profile=aws-eks expected exactly 2 generator elements, found $aws_generator_elements" >&2
  fail=1
else
  echo "OK: profile=aws-eks renders exactly 2 generator elements"
fi
if grep -qE '^\s*- env: staging-aws$' "$aws_render_out" && grep -qE '^\s*- env: production-aws$' "$aws_render_out"; then
  echo "OK: profile=aws-eks generator elements are named exactly 'staging-aws'/'production-aws', per the addendum - not invented"
else
  echo "FAIL: profile=aws-eks generator elements do not match the addendum's exact names" >&2
  fail=1
fi
if grep -qE '^kind: SecretStore$|^kind: Secret$|auth:|serviceAccountRef|arn:aws:|AKIA[0-9A-Z]{16}' "$aws_render_out"; then
  echo "FAIL: the aws-eks profile render contains a SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped string" >&2
  fail=1
else
  echo "OK: the aws-eks profile render contains zero SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped content (this chart only ever emits a valueFiles reference - charts/standard-workload renders those later, offline-validated separately by check-standard-workload-chart.sh)"
fi

# --- positive: each aws-eks element's implied valueFiles ("values-
# {{.env}}.yaml", Argo CD's own templating, unresolved at `helm
# template` time) resolves to a tracked file that actually exists and
# is the CORRECT one for that environment - never swappable, since
# both the namespace and the valueFiles path are derived from the same
# single "env" field on the same generator element. ---
for env_ns in "staging-aws:staging-aws" "production-aws:production-aws"; do
  env="${env_ns%%:*}"; expected_ns="${env_ns##*:}"
  expected_values_file="charts/standard-workload/values-${env}.yaml"
  if [ ! -f "$expected_values_file" ]; then
    echo "FAIL: aws-eks environment '$env' has no matching values file at $expected_values_file" >&2
    fail=1
    continue
  fi
  actual_ns="$(awk -v e="- env: ${env}\$" '$0 ~ e {getline; print; exit}' "$aws_render_out" | sed -n 's/^[[:space:]]*namespace: //p')"
  if [ "$actual_ns" = "$expected_ns" ]; then
    echo "OK: aws-eks environment '$env' resolves to $expected_values_file and namespace '$expected_ns' - never swapped with the other environment"
  else
    echo "FAIL: aws-eks environment '$env' resolved to namespace '$actual_ns', expected '$expected_ns'" >&2
    fail=1
  fi
done

# --- negative: an unrecognized profile value fails the render closed,
# never silently defaulting to either local-kind or aws-eks ---
unknown_profile_out="$(mktemp)"
trap 'rm -f "$render_out" "$aws_render_out" "$unknown_profile_out"' EXIT INT TERM
if "$HELM_BIN" template gitops/bootstrap --set profile=azure > "$unknown_profile_out" 2>&1; then
  echo "FAIL: profile=azure (unknown) rendered successfully - must fail closed" >&2
  fail=1
elif grep -q 'unknown profile' "$unknown_profile_out"; then
  echo "OK: an unrecognized profile value ('azure') fails the render closed with the expected error"
else
  echo "FAIL: profile=azure failed, but not for the expected 'unknown profile' reason" >&2
  cat "$unknown_profile_out" >&2
  fail=1
fi
rm -f "$unknown_profile_out"

# --- negative: a malformed/extra aws-eks environment entry (self-test
# of the file-existence/namespace check above, not the schema - "cada
# fixture debe demostrar la causa exacta del rechazo", Phase 3.3.3's
# own established idiom) - built as a standalone values override, never
# editing the tracked values.yaml. ---
bad_env_values="$(mktemp)"
cat > "$bad_env_values" <<'BADENVEOF'
profile: "aws-eks"
awsEnvironments:
  - name: staging-aws
    namespace: production-aws
  - name: production-aws
    namespace: production-aws
  - name: staging-uat-aws
    namespace: staging-uat-aws
BADENVEOF
bad_env_out="$(mktemp)"
trap 'rm -f "$render_out" "$aws_render_out" "$bad_env_values" "$bad_env_out"' EXIT INT TERM
if ! "$HELM_BIN" template gitops/bootstrap -f "$bad_env_values" > "$bad_env_out" 2>&1; then
  echo "FAIL: the malformed-environment self-test fixture failed to render at all (expected: renders, but with detectably wrong content)" >&2
  cat "$bad_env_out" >&2
  fail=1
else
  bad_count="$(grep -cE '^\s*- env: ' "$bad_env_out" || true)"
  staging_aws_ns="$(awk '/^[[:space:]]*- env: staging-aws$/{getline; print; exit}' "$bad_env_out" | sed -n 's/^[[:space:]]*namespace: //p')"
  self_test_fail=0
  if [ "$bad_count" != "3" ]; then
    echo "FAIL: malformed-environment self-test fixture did not actually inject a third element (found $bad_count, expected 3) - fixture is broken" >&2
    self_test_fail=1
  fi
  if [ "$staging_aws_ns" = "production-aws" ]; then
    echo "OK: confirmed the namespace-consistency check above would catch a genuine cross-environment swap (staging-aws mapped to production-aws's namespace resolves to 'production-aws', not 'staging-aws')"
  else
    self_test_fail=1
  fi
  if [ ! -f "charts/standard-workload/values-staging-uat-aws.yaml" ]; then
    echo "OK: confirmed a 3rd, unauthorized aws-eks environment ('staging-uat-aws') has no matching values file - the file-existence check above would reject it (more or fewer than exactly 2 aws-eks environments is detectable)"
  else
    echo "FAIL: unexpected - charts/standard-workload/values-staging-uat-aws.yaml exists" >&2
    self_test_fail=1
  fi
  [ "$self_test_fail" -ne 0 ] && fail=1
fi
rm -f "$bad_env_values" "$bad_env_out"

# --- negative: fewer than 2 aws-eks environments is equally detectable
# by the same "exactly 2" counting check already applied to the real
# render above - self-tested here the same way. ---
short_env_values="$(mktemp)"
cat > "$short_env_values" <<'SHORTENVEOF'
profile: "aws-eks"
awsEnvironments:
  - name: staging-aws
    namespace: staging-aws
SHORTENVEOF
short_env_out="$(mktemp)"
trap 'rm -f "$render_out" "$aws_render_out" "$short_env_values" "$short_env_out"' EXIT INT TERM
if ! "$HELM_BIN" template gitops/bootstrap -f "$short_env_values" > "$short_env_out" 2>&1; then
  echo "FAIL: the fewer-than-2-environments self-test fixture failed to render at all" >&2
  fail=1
else
  short_count="$(grep -cE '^\s*- env: ' "$short_env_out" || true)"
  if [ "$short_count" = "1" ]; then
    echo "OK: confirmed a fixture with only 1 aws-eks environment renders exactly 1 generator element - the 'exactly 2' check above would correctly reject it"
  else
    echo "FAIL: fewer-than-2-environments self-test produced $short_count elements, expected 1" >&2
    fail=1
  fi
fi
rm -f "$short_env_values" "$short_env_out"

if [ "$fail" -ne 0 ]; then
  echo "gitops-render: FAILED"
  exit 1
fi
echo "gitops-render: OK"
