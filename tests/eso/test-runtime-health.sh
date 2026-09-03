#!/bin/sh
# Read-only runtime health checks against an already-installed External
# Secrets Operator bootstrap: all 25 CRDs Established, both scoped
# releases' Deployments Ready, the webhook/cert-controller singleton
# present exactly once (owned by eso-staging), each controller's own
# Role scoped to exactly its own namespace (live, not just rendered),
# and no wildcard verb/resource/apiGroup in any live Role. Never
# mutates anything. Backs `make eso-test-runtime-health` only.
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

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi
require_helm

fail=0

echo "test-runtime-health: checking all 25 CRDs are Established ..."
established=0
while IFS= read -r crd; do
  [ -z "$crd" ] && continue
  if pkubectl get "customresourcedefinition/${crd}" \
       -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q "^True$"; then
    established=$((established + 1))
  else
    echo "FAIL: CRD '$crd' is not Established" >&2
    fail=1
  fi
done <<EOF
$(eso_crd_names)
EOF
[ "$established" -eq 25 ] && echo "OK: all 25 CRDs Established"

while IFS='|' read -r env_name ns release webhook_create cert_create; do
  [ -z "$env_name" ] && continue
  echo "test-runtime-health: checking $env_name (namespace $ns, release $release) ..."

  if ! eso_release_exists "$ns" "$release"; then
    echo "FAIL: release '$release' not installed - run 'make eso-install' first" >&2
    fail=1
    continue
  fi

  dep="${release}-external-secrets"
  desired="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || desired=""
  ready="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || ready=""
  if [ -z "$desired" ] || [ "$ready" != "$desired" ]; then
    echo "FAIL: Deployment/$dep in $ns not Ready (ready='$ready' desired='$desired')" >&2
    fail=1
  else
    echo "OK: Deployment/$dep ready ($ready/$desired)"
  fi

  # Controller's own Role is scoped to exactly its own workload
  # namespace - live, not just rendered.
  role_name="${release}-external-secrets-controller"
  if ! pkubectl get role "$role_name" -n "$env_name" >/dev/null 2>&1; then
    echo "FAIL: expected Role/$role_name in namespace '$env_name' not found" >&2
    fail=1
  else
    echo "OK: Role/$role_name present, scoped to namespace '$env_name'"
  fi
  if pkubectl get clusterrole "$role_name" >/dev/null 2>&1; then
    echo "FAIL: $role_name exists as a ClusterRole - scopedRBAC did not take effect live" >&2
    fail=1
  fi

  # Structural (field-aware) wildcard scan of the LIVE Role, not a blind
  # grep - reuses the same YAML-structural scanner the offline render
  # gate uses (scripts/eso/_lib.sh), applied to `-o yaml` output so the
  # same field-tracking logic is valid (kubectl's `-o json` array
  # formatting is not the shape this scanner is written for).
  role_yaml="$(mktemp)"
  pkubectl get role "$role_name" -n "$env_name" -o yaml > "$role_yaml" 2>/dev/null
  wildcard_hits="$(eso_check_no_rbac_wildcards "$role_yaml")"
  rm -f "$role_yaml"
  if [ -n "$wildcard_hits" ]; then
    echo "FAIL: live Role/$role_name contains a structural wildcard:" >&2
    printf '%s\n' "$wildcard_hits" >&2
    fail=1
  fi

  if [ "$webhook_create" = "true" ]; then
    if pkubectl get validatingwebhookconfiguration externalsecret-validate secretstore-validate >/dev/null 2>&1; then
      echo "OK: webhook ValidatingWebhookConfigurations present (owned by $release)"
    else
      echo "FAIL: expected webhook ValidatingWebhookConfigurations missing" >&2
      fail=1
    fi
    cc_dep="${release}-external-secrets-cert-controller"
    cc_ready="$(pkubectl -n "$ns" get deployment "$cc_dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || cc_ready=""
    [ "$cc_ready" = "1" ] && echo "OK: cert-controller Deployment ready" || { echo "FAIL: cert-controller Deployment not ready" >&2; fail=1; }
  fi
done <<EOF
$(eso_environments)
EOF

echo "test-runtime-health: checking no unhealthy pods across eso-staging/eso-production ..."
for ns in eso-staging eso-production; do
  bad_pods="$(pkubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print}')"
  if [ -n "$bad_pods" ]; then
    echo "FAIL: unhealthy pod(s) in namespace '$ns':" >&2
    printf '%s\n' "$bad_pods" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "OK: all pods Running or Completed"

if [ "$fail" -ne 0 ]; then
  echo "test-runtime-health: FAILED"
  exit 1
fi
echo "test-runtime-health: OK"
