#!/bin/sh
# Creates (or tears down) the imperative, out-of-Git source Secret that
# ESO's kubernetes-provider SecretStore reads from, for exactly one
# environment - this script, not Git, not any chart template, is the
# only place secret material ever passes through in this phase.
#
# Phase 2.6.3b semantics (see
# .local/evidence/phase-2.6.3-gitops-lifecycle-hardening-plan.md, Gap
# 4): the DEFAULT (no-flag) invocation is ensure/create-if-absent -
# if the Secret already exists, this is a TRUE no-op: it is never
# read, never re-applied, and the value is never prompted for or
# consumed from stdin. A second identical invocation preserves the
# Secret's UID, resourceVersion, content hash, and every RBAC/
# namespace object untouched. Rotating an EXISTING value requires the
# explicit --rotate flag.
#
# The value is read ONLY from stdin (piped, or interactively with echo
# disabled) - never a CLI argument, never an environment variable set
# on the command line, never a literal in this script's own source.
# This script never echoes, cats, or otherwise prints the value; its
# own stdout is limited to resource names, namespaces, byte length,
# UID/resourceVersion, and a SHA256 of the value (for later drift
# comparison) - never the value itself. No `set -x` anywhere in this
# file; tracing is also explicitly disabled right before any sensitive
# material is read, in case the caller's shell inherited it enabled.
#
# Usage:
#   sh lab/eso/provision-source-secret.sh staging               # ensure: create if absent, true no-op if present (never reads stdin/prompt when present)
#   printf '%s' "$VALUE" | sh lab/eso/provision-source-secret.sh staging --rotate   # rotate an EXISTING Secret's value only
#   sh lab/eso/provision-source-secret.sh staging --delete       # idempotent teardown (unchanged, unrelated to ensure/rotate)
#
# Also idempotently creates the source namespace and the narrow
# Role/RoleBinding granting exactly the environment's dedicated auth
# ServiceAccount (staging-secretstore-reader / production-
# secretstore-reader - rendered by charts/standard-workload, not this
# script) get/list/watch on exactly the one named source Secret - never
# a wildcard resourceName, never cluster-scoped. Only done on the
# create path (Secret absent) - never touched on the ensure no-op path
# or the --rotate path, which only ever update the Secret itself.
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

# Closed allowlist - reject any other value BEFORE any mutation, and
# before reading anything from stdin.
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
    echo "FAIL: usage: sh lab/eso/provision-source-secret.sh <staging|production> [--rotate|--delete]" >&2
    exit 1
    ;;
esac

case "$action" in
  ""|--rotate|--delete) : ;;
  *)
    echo "FAIL: unrecognized second argument '$action' - only '--rotate' or '--delete' is supported" >&2
    exit 1
    ;;
esac

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

escaped_owner_key="$(printf '%s' "$OWNER_LABEL_KEY" | sed 's/\./\\./g')"

# --- teardown: idempotent, ownership-checked, no secret material
# involved at all. Unchanged from before - never a side effect of
# ensure or --rotate. ---
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

secret_exists=0
if pkubectl get secret "$source_secret" -n "$source_ns" >/dev/null 2>&1; then
  secret_exists=1
fi

# --- ensure (no flag), Secret already present: TRUE no-op. Never
# reads stdin/prompt, never re-applies anything, never touches
# namespace/RBAC - the exact state (UID, resourceVersion, content
# hash, and every other object) is left byte-for-byte as it was. ---
if [ "$action" = "" ] && [ "$secret_exists" -eq 1 ]; then
  existing_uid="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.metadata.uid}')"
  existing_rv="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.metadata.resourceVersion}')"
  existing_sha256="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
  echo "OK: Secret '$source_secret' already exists in '$source_ns' - true no-op (uid=${existing_uid} resourceVersion=${existing_rv} sha256=${existing_sha256}) - value never printed, never read, never re-applied"
  exit 0
fi

if [ "$action" = "--rotate" ] && [ "$secret_exists" -eq 0 ]; then
  echo "FAIL: --rotate requires the Secret '$source_secret' to already exist in '$source_ns' - omit the flag to create it first" >&2
  exit 1
fi

# --- capture pre-mutation state (for --rotate's before/after evidence;
# harmless no-op reads for the plain create path where nothing exists
# yet). ---
pre_uid=""
pre_rv=""
pre_sha256=""
if [ "$secret_exists" -eq 1 ]; then
  pre_uid="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.metadata.uid}')"
  pre_rv="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.metadata.resourceVersion}')"
  pre_sha256="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.data.message}' | base64 -d | shasum -a 256 | awk '{print $1}')"
fi

# --- read the value: piped stdin if available, otherwise an
# interactive, echo-disabled prompt. Never a CLI argument, never
# --from-literal. Tracing explicitly disabled right before any
# sensitive material is read or written, regardless of whether it was
# already off (defense in depth against an inherited `set -x`). ---
set +x 2>/dev/null || true
umask 077
tmpdir="$(mktemp -d .local/tmp.XXXXXX)"
tmpfile="${tmpdir}/message"
cleanup() {
  rm -rf "$tmpdir"
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

if [ "$action" = "--rotate" ]; then
  # --- rotate: update only. Never touches the namespace or RBAC -
  # both already exist (the Secret existing implies they do too, since
  # the create path always provisions them together). ---
  pkubectl create secret generic "$source_secret" \
    --namespace "$source_ns" \
    --from-file="message=${tmpfile}" \
    --dry-run=client -o yaml \
    | pkubectl apply -f - >/dev/null
  post_uid="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.metadata.uid}')"
  post_rv="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.metadata.resourceVersion}')"
  if [ "$post_uid" != "$pre_uid" ]; then
    echo "FAIL: Secret UID changed during rotate ($pre_uid -> $post_uid) - this must be an update, never a delete+recreate" >&2
    exit 1
  fi
  if [ "$value_sha256" = "$pre_sha256" ]; then
    echo "OK: rotate applied the same value to '$source_secret' in '$source_ns' - hash unchanged (sha256 ${value_sha256}), uid unchanged (${post_uid}), resourceVersion ${pre_rv} -> ${post_rv}, ${value_bytes} bytes - value never printed"
  else
    echo "OK: rotated '$source_secret' in '$source_ns' - sha256 ${pre_sha256} -> ${value_sha256}, uid unchanged (${post_uid}), resourceVersion ${pre_rv} -> ${post_rv}, ${value_bytes} bytes - value never printed"
  fi
  exit 0
fi

# --- create (ensure, Secret absent): namespace + Secret + RBAC,
# exactly as before. ---
if ! pkubectl get namespace "$source_ns" >/dev/null 2>&1; then
  pkubectl create namespace "$source_ns"
  pkubectl label namespace "$source_ns" "${OWNER_LABEL_KEY}=${OWNER_LABEL_VALUE}" --overwrite
  echo "OK: namespace '$source_ns' created and labeled"
else
  echo "OK: namespace '$source_ns' already exists"
fi

pkubectl create secret generic "$source_secret" \
  --namespace "$source_ns" \
  --from-file="message=${tmpfile}" \
  --dry-run=client -o yaml \
  | pkubectl apply -f - >/dev/null
created_uid="$(pkubectl get secret "$source_secret" -n "$source_ns" -o jsonpath='{.metadata.uid}')"
echo "OK: Secret '$source_secret' created in namespace '$source_ns' (uid=${created_uid} sha256=${value_sha256} ${value_bytes} bytes) - value never printed"

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
