#!/bin/sh
# Read-only health/identity report for the External Secrets Operator
# bootstrap: CRD count and Established status, both scoped releases'
# Helm status, and their Deployments' readiness. Never mutates
# anything. Backs `make eso-status`.
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

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

fail=0

established=0
total=0
while IFS= read -r crd; do
  [ -z "$crd" ] && continue
  total=$((total + 1))
  if pkubectl get "customresourcedefinition/${crd}" \
       -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q "^True$"; then
    established=$((established + 1))
  fi
done <<EOF
$(eso_crd_names)
EOF
if [ "$established" -eq "$total" ] && [ "$total" -eq 25 ]; then
  echo "OK: all 25 CRDs present and Established"
else
  echo "FAIL: $established/$total CRDs Established (expected 25/25)" >&2
  fail=1
fi

while IFS='|' read -r env_name ns release webhook_create cert_create; do
  [ -z "$env_name" ] && continue
  echo "--- $env_name (namespace $ns, release $release) ---"
  if ! eso_release_exists "$ns" "$release"; then
    echo "FAIL: release '$release' not found in namespace '$ns'" >&2
    fail=1
    continue
  fi
  phelm status "$release" -n "$ns" -o json 2>/dev/null | sed -n 's/.*"status":"\([^"]*\)".*/status: \1/p' | head -1
  pkubectl get deploy -n "$ns" -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' 2>&1
  if [ "$webhook_create" = "true" ]; then
    pkubectl get validatingwebhookconfiguration externalsecret-validate secretstore-validate >/dev/null 2>&1 \
      && echo "OK: webhook ValidatingWebhookConfigurations present" \
      || { echo "FAIL: expected webhook ValidatingWebhookConfigurations missing" >&2; fail=1; }
  fi
done <<EOF
$(eso_environments)
EOF

if [ "$fail" -ne 0 ]; then
  echo "eso-status: FAILED"
  exit 1
fi
echo "eso-status: OK"
