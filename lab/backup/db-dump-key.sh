#!/bin/sh
# Phase 6.3d (ADR-0022 amendment, ADR-0023): the store credential the
# reference application's database dumps use, for one environment. Backs
# `make db-dump-key ENV=<dev|uat|prod> [LAB_CLUSTER=<env>]`.
#
#   - store user dumps-<env> and its own bucket dumps-<env> (kept if
#     present). Velero's users cannot read it, and it cannot read theirs.
#   - Secret eso-source-<env>/dumps-<env> with access-key-id and
#     secret-access-key, always reconciled from the store's IAM file (the
#     store is the source of truth; an identical apply is a no-op).
#     Never printed, never on a command line.
#   - Role + RoleBinding dumps-<env>-reader: get/list/watch on that one
#     Secret for <env>-postgres-reader (charts/postgres-lab's SecretStore).
# Velero already backs up eso-source-<env>, so a rebuilt spoke gets the
# same key back. The store must be running (make backup-store-up) and the
# source namespace must exist (make eso-install).
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
. scripts/backup/_lib.sh
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }
bk_store_running || { echo "FAIL: store '$BK_STORE_CONTAINER' not running - make backup-store-up" >&2; exit 1; }

user="dumps-${env_name}"
source_ns="eso-source-${env_name}"
secret="dumps-${env_name}"
pkubectl get namespace "$source_ns" >/dev/null 2>&1 || { echo "FAIL: namespace '$source_ns' does not exist - run make eso-install first" >&2; exit 1; }

# The dump pods reach the store through an egress rule for
# charts/postgres-lab's dump.storeCIDR: the store's address must be in it.
cidr="$(.tools/bin/yq '.dump.storeCIDR' charts/postgres-lab/values.yaml)"
ip="$(docker inspect "$BK_STORE_CONTAINER" -f "{{(index .NetworkSettings.Networks \"$BK_STORE_NETWORK\").IPAddress}}")"
python3 -I -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)' "$ip" "$cidr" \
  || { echo "FAIL: store address $ip is outside dump.storeCIDR $cidr (charts/postgres-lab/values.yaml) - the dump Job could not reach it" >&2; exit 1; }
echo "OK: store address $ip is inside dump.storeCIDR $cidr"
bk_store_ensure_user "$user" "$user" >/dev/null
echo "OK: store user '$user' owns bucket '$user'"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
printf '%s' "$user" > "$work/access-key-id"
bk_store_user_secret "$user" > "$work/secret-access-key"
[ -s "$work/secret-access-key" ] || { echo "FAIL: no store key for '$user'" >&2; exit 1; }
pkubectl -n "$source_ns" create secret generic "$secret" --from-file="$work" --dry-run=client -o yaml \
  | pkubectl apply -f - >/dev/null
echo "OK: Secret '$source_ns/$secret' matches the store's key for '$user' (access-key-id, secret-access-key) - never printed"

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
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${secret}-reader
YAML
echo "OK: Role/RoleBinding '${secret}-reader' in '$source_ns': get/list/watch on '$secret' only, for ${env_name}/${env_name}-postgres-reader"
