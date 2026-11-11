#!/bin/sh
# Registers one spoke with the hub's Argo CD (Phase 2.7.3, ADR-0015,
# decisions D1/D2 of the phase plan). Usage: sh lab/multicluster/
# spoke-register.sh <dev|uat|prod>. Backs `make mc-spoke-register`.
#
# On the spoke (server-side apply, one stable field manager, idempotent):
#   - the workload namespace <env>, labelled Pod Security "restricted"
#     and owned by this registration. Pre-created here so Argo CD never
#     needs a cluster-scoped grant (no CreateNamespace, no Namespace
#     permission) - D1.
#   - namespace argocd-access with ServiceAccount argocd-manager.
#   - a Role + RoleBinding in <env> granting exactly the kinds the
#     platform AppProject allows (ConfigMap, Service, ServiceAccount,
#     Deployment, SecretStore, ExternalSecret). Never Secret, never a
#     wildcard, never a ClusterRole.
# On the hub:
#   - Argo CD cluster Secret spoke-<env> (label platform.environment=<env>)
#     scoped with namespaces=<env> and clusterResources=false, holding the
#     spoke's CA and a fresh, bounded TokenRequest token (24h) - D2.
#
# Every run issues a NEW token (re-running is how the credential is
# rotated). The token is never printed, never written to disk, and
# never passed as a command-line argument: it only ever travels on
# stdin into `kubectl apply`. Only its expiry time is reported.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools
. lab/multicluster/_lib.sh

spoke="${1:-}"
lab_mc_require_spoke "$spoke"

for m in "$LAB_MC_HUB" "$spoke"; do
  if ! lab_mc_identity "$m"; then
    echo "FAIL: mc-spoke-register: member '$m' is not a matching project cluster ($LAB_MC_IDENTITY_CASE) - run 'make lab-mc-create' first" >&2
    exit 1
  fi
done
if ! ckubectl "$LAB_MC_HUB" get namespace argocd >/dev/null 2>&1; then
  echo "FAIL: mc-spoke-register: Argo CD is not installed on the hub - run 'make argocd-install LAB_CLUSTER=hub' first" >&2
  exit 1
fi

# --- 1. spoke-side objects ---
cat <<EOF | ckubectl "$spoke" apply --server-side --field-manager="$LAB_MC_FIELD_MANAGER" -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${spoke}
  labels:
    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.36
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.36
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.36
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${LAB_MC_ACCESS_NS}
  labels:
    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${LAB_MC_ACCESS_SA}
  namespace: ${LAB_MC_ACCESS_NS}
  labels:
    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${LAB_MC_ACCESS_SA}
  namespace: ${spoke}
  labels:
    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}
rules:
  - apiGroups: [""]
    resources: ["configmaps", "services", "serviceaccounts"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["external-secrets.io"]
    resources: ["secretstores", "externalsecrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${LAB_MC_ACCESS_SA}
  namespace: ${spoke}
  labels:
    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${LAB_MC_ACCESS_SA}
subjects:
  - kind: ServiceAccount
    name: ${LAB_MC_ACCESS_SA}
    namespace: ${LAB_MC_ACCESS_NS}
EOF
echo "OK: spoke '$spoke': namespace '$spoke' (PSA restricted), ${LAB_MC_ACCESS_NS}/${LAB_MC_ACCESS_SA}, and a namespace-scoped Role/RoleBinding applied (no ClusterRole)"

# --- 2. fresh bounded token + spoke CA (never printed) ---
token="$(ckubectl "$spoke" -n "$LAB_MC_ACCESS_NS" create token "$LAB_MC_ACCESS_SA" --duration="$LAB_MC_TOKEN_DURATION")"
[ -n "$token" ] || { echo "FAIL: TokenRequest returned an empty token" >&2; exit 1; }
ca_data="$(ckubectl "$spoke" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[ -n "$ca_data" ] || { echo "FAIL: could not read the spoke's CA from its kubeconfig" >&2; exit 1; }

# exp claim only - decoded from the JWT payload, base64url -> base64.
payload="$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')"
pad=$(( (4 - ${#payload} % 4) % 4 ))
while [ "$pad" -gt 0 ]; do payload="${payload}="; pad=$((pad - 1)); done
exp_epoch="$(printf '%s' "$payload" | base64 -d 2>/dev/null | sed -n 's/.*"exp":\([0-9]*\).*/\1/p')"
[ -n "$exp_epoch" ] || { echo "FAIL: could not read the token's exp claim" >&2; exit 1; }
exp_iso="$(date -u -r "$exp_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$exp_epoch" +%Y-%m-%dT%H:%M:%SZ)"

server="$(lab_mc_internal_server "$spoke")"

# --- 3. hub cluster Secret (token travels on stdin only) ---
{
cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: spoke-${spoke}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    ${LAB_MC_ENV_LABEL_KEY}: ${spoke}
    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}
  annotations:
    eks-gitops-lab-lite.local/token-expires: "${exp_iso}"
type: Opaque
stringData:
  name: spoke-${spoke}
  server: ${server}
  namespaces: ${spoke}
  clusterResources: "false"
  config: |
EOF
printf '    {"bearerToken": "%s", "tlsClientConfig": {"insecure": false, "caData": "%s"}}\n' "$token" "$ca_data"
} | ckubectl "$LAB_MC_HUB" apply --server-side --force-conflicts=false --field-manager="$LAB_MC_FIELD_MANAGER" -f - >/dev/null
token=""

echo "OK: hub cluster Secret 'spoke-${spoke}' applied (server ${server}, namespaces=${spoke}, clusterResources=false, label ${LAB_MC_ENV_LABEL_KEY}=${spoke}); token expires ${exp_iso} - token never printed"
echo "mc-spoke-register: OK ($spoke)"
