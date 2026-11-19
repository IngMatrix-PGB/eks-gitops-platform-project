#!/bin/sh
# Phase 6.3b (ADR-0023): the reference application's database credentials
# for one environment, outside Git. Backs
# `make eso-provision-db-secret ENV=<dev|uat|prod> [LAB_CLUSTER=<env>]`.
#
#   - Secret eso-source-<env>/db-<env> with two keys, superuser-password
#     and app-password: random, generated here, never printed or put on a
#     command line. Already present -> left exactly as it is (never read,
#     never rotated): a restored or existing value survives.
#   - Role + RoleBinding db-<env>-reader in eso-source-<env>: get/list/
#     watch on that one Secret for the two SecretStore identities that read
#     it - <env>-postgres-reader (charts/postgres-lab) and <env>-notes-
#     reader (the notes workload's ExternalSecret). Applied on every run,
#     so a missing grant is repaired (the 6.2b drill showed RBAC lost while
#     a Secret survived).
# The source namespace must exist (make eso-install creates it).
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
env_name="${1:-}"
case "$env_name" in dev|uat|prod) : ;; *) echo "usage: $0 <dev|uat|prod>" >&2; exit 2 ;; esac
LAB_CLUSTER="${LAB_CLUSTER:-$env_name}"
export LAB_CLUSTER
. scripts/lab/_lib.sh
require_repo_root
require_tools
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }

source_ns="eso-source-${env_name}"
secret="db-${env_name}"
pkubectl get namespace "$source_ns" >/dev/null 2>&1 || { echo "FAIL: namespace '$source_ns' does not exist - run make eso-install first" >&2; exit 1; }

if pkubectl -n "$source_ns" get secret "$secret" >/dev/null 2>&1; then
  echo "OK: Secret '$source_ns/$secret' already exists - left as it is (never read, never rotated)"
else
  set +x 2>/dev/null || true
  umask 077
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT INT TERM
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "$work/superuser-password"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "$work/app-password"
  [ -s "$work/superuser-password" ] && [ -s "$work/app-password" ] || { echo "FAIL: could not generate passwords" >&2; exit 1; }
  pkubectl -n "$source_ns" create secret generic "$secret" --from-file="$work" --dry-run=client -o yaml \
    | pkubectl apply -f - >/dev/null
  echo "OK: Secret '$source_ns/$secret' created with two random passwords (superuser-password, app-password) - never printed"
fi

pkubectl apply -f - >/dev/null <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${secret}-reader
  namespace: ${source_ns}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["${secret}"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${secret}-reader
  namespace: ${source_ns}
subjects:
  - kind: ServiceAccount
    name: ${env_name}-postgres-reader
    namespace: ${env_name}
  - kind: ServiceAccount
    name: ${env_name}-notes-reader
    namespace: ${env_name}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${secret}-reader
YAML
echo "OK: Role/RoleBinding '${secret}-reader' in '$source_ns': get/list/watch on '$secret' only, for ${env_name}/${env_name}-postgres-reader and ${env_name}/${env_name}-notes-reader"
