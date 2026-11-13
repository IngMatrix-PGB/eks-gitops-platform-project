#!/bin/sh
# Fully offline Helm render of gitops/bootstrap, plus proof that it
# renders exactly the authorized shape: one AppProject, one
# ApplicationSet with exactly three list elements (local-kind) or exactly
# one clusters generator (local-multicluster, Phase 2.7.4; aws-eks,
# Phase 3.4.4b), zero Secrets, no
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
if [ "$generator_elements" != "3" ]; then
  echo "FAIL: expected exactly 3 generator list elements, found $generator_elements" >&2
  fail=1
else
  echo "OK: exactly 3 generator elements (dev, uat, prod)"
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
# Phase 3.4.4b: the default (local-kind) render never reaches a spoke or
# AWS. aws-eks and local-multicluster are both hub-and-spoke and are
# checked by check_hub_spoke below. Nothing here contacts a cluster or AWS.
# =============================================================================
if grep -qE '^\s*- clusters:$' "$render_out"; then
  echo "FAIL: the default render contains a clusters generator - a spoke profile must never activate by omission" >&2
  fail=1
else
  echo "OK: the default render (profile unset) has no clusters generator - no spoke profile activates by omission"
fi
if grep -qiE '^kind: SecretStore$|^kind: Secret$|auth:|serviceAccountRef|arn:aws:|AKIA[0-9A-Z]{16}' "$render_out"; then
  echo "FAIL: the default render contains a SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped string - this chart must never render workload-level resources at all" >&2
  fail=1
else
  echo "OK: the default render contains zero SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped content"
fi
# AppProject document only (the ApplicationSet also has namespace: lines).
appproject_doc="$(awk '/^kind: AppProject$/{f=1} f && /^kind: ApplicationSet$/{exit} f{print}' "$render_out")"
local_dest_count="$(printf '%s\n' "$appproject_doc" | grep -cE 'namespace: (dev|uat|prod)$' || true)"
other_dest_count="$(printf '%s\n' "$appproject_doc" | grep -cE '^\s*- name: |namespace: [a-z]+-aws$' || true)"
if [ "$local_dest_count" = "3" ] && [ "$other_dest_count" = "0" ]; then
  echo "OK: default AppProject destinations are exactly dev/uat/prod in-cluster - no spoke and no *-aws destination (Phase 3.4.4b removed the always-on aws ones)"
else
  echo "FAIL: default AppProject destinations unexpected (local=$local_dest_count, expected 3; spoke/aws=$other_dest_count, expected 0)" >&2
  fail=1
fi

# --- negative: an unrecognized profile value fails the render closed ---
unknown_profile_out="$(mktemp)"
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

# --- Phase 2.8.2: local-kind lets an HPA own Deployment spec.replicas
# (ignoreDifferences on exactly that pointer + RespectIgnoreDifferences) ---
igd="$(awk '/ignoreDifferences:/{f=1} f&&/destination:/{exit} f{print}' "$render_out")"
if printf '%s\n' "$igd" | grep -qE '^\s+- group: apps$' && printf '%s\n' "$igd" | grep -qE '^\s+kind: Deployment$' \
   && ! printf '%s\n' "$igd" | grep -q 'jsonPointers:' \
   && [ "$(printf '%s\n' "$igd" | grep -cE "^\s+- 'select")" = "1" ] \
   && printf '%s\n' "$igd" | grep -qF -- "- 'select(.metadata.annotations[\"eks-gitops-lab-lite.local/replicas-owner\"] == \"hpa\") | .spec.replicas'" \
   && grep -qE '^\s+- RespectIgnoreDifferences=true$' "$render_out"; then
  echo "OK: local-kind ignores spec.replicas only on Deployments annotated replicas-owner=hpa, with RespectIgnoreDifferences=true"
else
  echo "FAIL: local-kind does not ignore exactly spec.replicas of HPA-owned Deployments (replicas-owner=hpa) with RespectIgnoreDifferences=true" >&2
  fail=1
fi

# =============================================================================
# Hub-and-spoke profiles (Phase 2.7.4 local-multicluster, Phase 3.4.4b
# aws-eks): hub Argo CD -> spokes through a clusters generator. Offline
# shape only - which spokes actually get an Application is proven at
# runtime (tests/multicluster/test-e2e.sh for the lab; Phase 6.4 for EKS).
#   check_hub_spoke <profile> <owner label value> <other profile's owner> <overlay suffix>
# =============================================================================
check_hub_spoke() {
  local prof="$1" owner="$2" other_owner="$3" suffix="$4" out hs_fail=0
  echo "gitops-render: helm lint (profile=$prof) ..."
  if ! "$HELM_BIN" lint gitops/bootstrap --set "profile=$prof" >/dev/null; then
    echo "FAIL: helm lint failed for profile=$prof" >&2
    fail=1
  fi
  out="$(mktemp)"
  if ! "$HELM_BIN" template gitops/bootstrap --set "profile=$prof" --set "gitRevision=${revision}" > "$out" 2>&1; then
    echo "FAIL: helm template failed for profile=$prof" >&2
    cat "$out" >&2
    rm -f "$out"; fail=1; return
  fi
  [ "$(grep -c '^kind: AppProject$' "$out")" = "1" ] || { echo "FAIL: $prof: expected exactly 1 AppProject" >&2; hs_fail=1; }
  [ "$(grep -c '^kind: ApplicationSet$' "$out")" = "1" ] || { echo "FAIL: $prof: expected exactly 1 ApplicationSet" >&2; hs_fail=1; }
  if grep -qiE '^kind: SecretStore$|^kind: Secret$|auth:|serviceAccountRef|arn:aws:|AKIA[0-9A-Z]{16}' "$out"; then
    echo "FAIL: $prof: render contains a SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped string" >&2; hs_fail=1
  fi
  [ "$(grep -cE '^\s*- clusters:$' "$out")" = "1" ] || { echo "FAIL: $prof: expected exactly 1 clusters generator" >&2; hs_fail=1; }
  [ "$(grep -cE '^\s*- list:$' "$out" || true)" = "0" ] || { echo "FAIL: $prof: a list generator is still rendered" >&2; hs_fail=1; }
  grep -qE "^\s*eks-gitops-lab-lite\.local/owner: ${owner}$" "$out" || { echo "FAIL: $prof: selector lacks owner label value '$owner'" >&2; hs_fail=1; }
  if grep -qE "owner: ${other_owner}$" "$out"; then
    echo "FAIL: $prof: selector would also match the other profile's spoke Secrets ('$other_owner')" >&2; hs_fail=1
  fi
  grep -qE '^\s*- key: platform\.environment$' "$out" || { echo "FAIL: $prof: selector lacks the platform.environment expression" >&2; hs_fail=1; }
  local sel_values
  sel_values="$(awk '/- key: platform\.environment$/{f=1} f && /^[[:space:]]*- (dev|uat|prod|[a-z-]+)$/{printf "%s ", $2} f && /values:$/ && ++v==2 {exit}' "$out")"
  [ "$sel_values" = "dev uat prod " ] || { echo "FAIL: $prof: selector environments are '$sel_values', expected exactly 'dev uat prod'" >&2; hs_fail=1; }
  local project appset
  project="$(awk '/^kind: AppProject$/{f=1} f && /^kind: ApplicationSet$/{exit} f{print}' "$out")"
  [ "$(printf '%s\n' "$project" | grep -cE '^\s*- name: spoke-(dev|uat|prod)$')" = "3" ] || { echo "FAIL: $prof: AppProject must allow exactly spoke-dev/spoke-uat/spoke-prod" >&2; hs_fail=1; }
  for e in dev uat prod; do
    printf '%s\n' "$project" | grep -A1 -E "^\s*- name: spoke-${e}$" | grep -qE "^\s*namespace: ${e}$" || { echo "FAIL: $prof: AppProject destination spoke-${e} is not bound to namespace ${e}" >&2; hs_fail=1; }
  done
  if printf '%s\n' "$project" | grep -qE 'server: |name: "?\*"?$|namespace: "?\*"?$|namespace: [a-z]+-aws$'; then
    echo "FAIL: $prof: AppProject has a server-based, wildcard or *-aws destination (the hub must be unreachable)" >&2; hs_fail=1
  fi
  printf '%s\n' "$project" | grep -qE '^\s*clusterResourceWhitelist: \[\]$' || { echo "FAIL: $prof: clusterResourceWhitelist must be empty" >&2; hs_fail=1; }
  appset="$(awk '/^kind: ApplicationSet$/{f=1} f{print}' "$out")"
  printf '%s\n' "$appset" | grep -qE '^\s*- CreateNamespace=false$' || { echo "FAIL: $prof: CreateNamespace=false missing" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -qF 'replicas-owner"] == "hpa") | .spec.replicas' && printf '%s\n' "$appset" | grep -qE '^\s+- RespectIgnoreDifferences=true$' || { echo "FAIL: $prof: HPA hand-over settings (ignoreDifferences on replicas-owner=hpa Deployments + RespectIgnoreDifferences) missing" >&2; hs_fail=1; }
  if printf '%s\n' "$appset" | grep -qE 'CreateNamespace=true|managedNamespaceMetadata:|server: https://kubernetes\.default\.svc'; then
    echo "FAIL: $prof: template still creates namespaces or targets the hub's in-cluster server" >&2; hs_fail=1
  fi
  printf '%s\n' "$appset" | grep -qE '^\s*name: "\{\{\.name\}\}"$' || { echo "FAIL: $prof: destination is not the generated cluster name" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -qE '^\s*namespace: "\{\{\.values\.env\}\}"$' || { echo "FAIL: $prof: destination namespace is not the spoke's environment" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -qF -- "- \"values-{{.values.env}}${suffix}.yaml\"" || { echo "FAIL: $prof: valueFiles is not values-{{.values.env}}${suffix}.yaml" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -q "targetRevision: ${revision}" || { echo "FAIL: $prof: revision '${revision}' not propagated" >&2; hs_fail=1; }
  for e in dev uat prod; do
    [ -f "charts/standard-workload/values-${e}${suffix}.yaml" ] || { echo "FAIL: $prof: values-${e}${suffix}.yaml missing" >&2; hs_fail=1; }
  done
  # self-test: an extra 'qa' environment in this profile's list is caught
  local key qa_values qa_sel
  key="$([ "$prof" = "aws-eks" ] && echo awsEks || echo multicluster)"
  qa_values="$(mktemp)"
  printf 'profile: "%s"\n%s:\n  environments: [dev, uat, prod, qa]\n' "$prof" "$key" > "$qa_values"
  qa_sel="$("$HELM_BIN" template gitops/bootstrap -f "$qa_values" 2>/dev/null | awk '/- key: platform\.environment$/{f=1} f && /^[[:space:]]*- [a-z-]+$/{printf "%s ", $2} f && /values:$/ && ++v==2 {exit}')"
  rm -f "$qa_values" "$out"
  if [ "$qa_sel" != "dev uat prod qa " ]; then
    echo "FAIL: $prof: selector self-test did not render the injected 'qa' environment (got '$qa_sel') - check is broken" >&2; hs_fail=1
  fi
  if [ "$hs_fail" -eq 0 ]; then
    echo "OK: profile=$prof renders 1 AppProject (spoke-dev/uat/prod by name, bound to dev/uat/prod, no cluster-scoped grant) and 1 ApplicationSet with exactly 1 clusters generator (owner=$owner + platform.environment in dev/uat/prod), CreateNamespace=false, destination by cluster name, values-<env>${suffix}.yaml, revision propagated; an extra 'qa' is detectable"
  else
    fail=1
  fi
}

check_hub_spoke local-multicluster multicluster-registration eks-spoke-registration ""
check_hub_spoke aws-eks eks-spoke-registration multicluster-registration "-aws"

if [ "$fail" -ne 0 ]; then
  echo "gitops-render: FAILED"
  exit 1
fi
echo "gitops-render: OK"
