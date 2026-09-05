#!/bin/sh
# Creates (or tears down) the imperative, out-of-Git source Secret that
# ESO's kubernetes-provider SecretStore reads from, for exactly one
# environment - this script, not Git, not any chart template, is the
# only place secret material ever passes through in this phase.
#
# The value is read ONLY from stdin (piped, or interactively with echo
# disabled) - never a CLI argument, never an environment variable set
# on the command line, never a literal in this script's own source.
# This script never echoes, cats, or otherwise prints the value; its
# own stdout is limited to resource names, namespaces, byte length, and
# a SHA256 of the value (for later drift comparison) - never the value
# itself. No `set -x` anywhere in this file.
#
# Usage:
#   printf '%s' "$VALUE" | sh lab/eso/provision-source-secret.sh staging
#   sh lab/eso/provision-source-secret.sh staging          # interactive prompt, echo disabled
#   sh lab/eso/provision-source-secret.sh staging --delete # idempotent teardown
#
# Also idempotently creates the source namespace and the narrow
# Role/RoleBinding granting exactly the environment's dedicated auth
# ServiceAccount (staging-secretstore-reader / production-
# secretstore-reader - rendered by charts/standard-workload, not this
# script) get/list/watch on exactly the one named source Secret - never
# a wildcard resourceName, never cluster-scoped.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root

OWNER_LABEL_KEY="eks-gitops-lab-lite.local/owner"
OWNER_LABEL_VALUE="eso-source-bootstrap"

env_name="${1:-}"
action="${2:-}"

case "$env_name" in
  staging)
    source_ns="eso-source-staging"
    source_secret="local-backend-staging"
    target_ns="staging"
    auth_sa="staging-secretstore-reader"
    ;;
  production)
    source_ns="eso-source-production"
    source_secret="local-backend-production"
    target_ns="production"
    auth_sa="production-secretstore-reader"
    ;;
  *)
    echo "FAIL: usage: sh lab/eso/provision-source-secret.sh <staging|production> [--delete]" >&2
    exit 1
    ;;
esac

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

escaped_owner_key="$(printf '%s' "$OWNER_LABEL_KEY" | sed 's/\./\\./g')"

# --- teardown: idempotent, ownership-checked, no secret material
# involved at all. ---
if [ "$action" = "--delete" ]; then
  if pkubectl get namespace "$source_ns" >/dev/null 2>&1; then
    owner_label="$(pkubectl get namespace "$source_ns" -o jsonpath="{.metadata.labels['${escaped_owner_key}']}" 2>/dev/null || true)"
    if [ "$owner_label" != "$OWNER_LABEL_VALUE" ]; then
      echo "FAIL: namespace '$source_ns' is not owned by this bootstrap (label mismatch) - refusing to delete" >&2
      exit 1
    fi
    pkubectl delete namespace "$source_ns" --wait --timeout=60s
    echo "OK: namespace '$source_ns' deleted"
  else
    echo "OK: namespace '$source_ns' already absent - no-op"
  fi
  exit 0
fi

if [ -n "$action" ]; then
  echo "FAIL: unrecognized second argument '$action' - only '--delete' is supported" >&2
  exit 1
fi

# --- read the value: piped stdin if available, otherwise an
# interactive, echo-disabled prompt. Never a CLI argument. ---
umask 077
mkdir -p .local
tmpfile="$(mktemp .local/tmp.XXXXXX)"
cleanup() {
  rm -f "$tmpfile"
}
trap cleanup EXIT INT TERM

if [ -t 0 ]; then
  printf 'Enter the source secret value for %s (input hidden, never echoed): ' "$env_name" >&2
  stty -echo 2>/dev/null || true
  IFS= read -r secret_value
  stty echo 2>/dev/null || true
  printf '\n' >&2
  printf '%s' "$secret_value" > "$tmpfile"
  unset secret_value
else
  cat > "$tmpfile"
fi

if [ ! -s "$tmpfile" ]; then
  echo "FAIL: no secret value was provided (empty input) - refusing to provision an empty Secret" >&2
  exit 1
fi

value_sha256="$(shasum -a 256 "$tmpfile" | awk '{print $1}')"
value_bytes="$(wc -c < "$tmpfile" | tr -d ' ')"

# --- source namespace (idempotent, owner-labeled) ---
if ! pkubectl get namespace "$source_ns" >/dev/null 2>&1; then
  pkubectl create namespace "$source_ns"
  pkubectl label namespace "$source_ns" "${OWNER_LABEL_KEY}=${OWNER_LABEL_VALUE}" --overwrite
  echo "OK: namespace '$source_ns' created and labeled"
else
  echo "OK: namespace '$source_ns' already exists"
fi

# --- source Secret: create-or-update, never printing the decoded
# value, never passing it as a CLI argument (kubectl reads the file
# directly via --from-file). ---
pkubectl create secret generic "$source_secret" \
  --namespace "$source_ns" \
  --from-file="message=${tmpfile}" \
  --dry-run=client -o yaml \
  | pkubectl apply -f - >/dev/null
echo "OK: Secret '$source_secret' provisioned in namespace '$source_ns' (sha256 ${value_sha256}, ${value_bytes} bytes) - value never printed"

# --- narrow Role/RoleBinding: exactly get/list/watch on exactly this
# one named Secret, for exactly the dedicated auth ServiceAccount in
# the target (workload) namespace - never a wildcard resourceName,
# never cluster-scoped. ---
role_name="${source_secret}-reader"
cat <<EOF | pkubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${role_name}
  namespace: ${source_ns}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["${source_secret}"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${role_name}
  namespace: ${source_ns}
subjects:
  - kind: ServiceAccount
    name: ${auth_sa}
    namespace: ${target_ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${role_name}
EOF
echo "OK: Role/RoleBinding '${role_name}' in '${source_ns}' grants exactly get/list/watch on '${source_secret}' to ServiceAccount '${target_ns}/${auth_sa}'"
