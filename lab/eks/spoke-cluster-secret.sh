#!/bin/sh
# Phase 3.4.4b (ADR-0015, TAD R-05): render - never apply - the hub Argo
# CD cluster Secret for one EKS spoke, from that spoke's terraform/envs/eks
# outputs. The EKS counterpart of the Secret lab/multicluster/
# spoke-register.sh applies for a kind spoke, with the same shape
# (name spoke-<env>, namespaces=<env>, clusterResources=false) and one
# difference: no token. Argo CD's controller and server assume
# awsAuthConfig.roleARN with their own Pod Identity credentials (Phase
# 3.4.4a) and mint short-lived EKS tokens themselves.
#
# Fully offline: never calls terraform, aws or kubectl, never reads state.
# The operator passes each output explicitly, e.g. from the spoke root:
#   terraform output -raw cluster_name
#   terraform output -raw cluster_endpoint
#   terraform output -raw cluster_certificate_authority_data
#   terraform output -raw argocd_manager_role_arn
# Fails closed on any value that does not match the spoke contract; prints
# the Secret on stdout only when every check passes.
#
# Usage:
#   lab/eks/spoke-cluster-secret.sh --env dev|uat|prod --cluster-name NAME \
#     --endpoint https://... --ca BASE64 --role-arn arn:aws:iam::...
set -eu

# The selection contract - must equal gitops/bootstrap/values.yaml awsEks
# (checked by tests/eks/test-spoke-cluster-secret.sh).
EKS_SPOKE_OWNER_LABEL_KEY="eks-gitops-lab-lite.local/owner"
EKS_SPOKE_OWNER_LABEL_VALUE="eks-spoke-registration"
EKS_SPOKE_ENV_LABEL_KEY="platform.environment"
EKS_SPOKE_NAME_PREFIX="spoke-"
EKS_SPOKE_ENVIRONMENTS="dev uat prod"

die() { echo "FAIL: $*" >&2; exit 1; }

env="" cluster_name="" endpoint="" ca="" role_arn=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "missing value for $1"
  case "$1" in
    --env) env="$2" ;;
    --cluster-name) cluster_name="$2" ;;
    --endpoint) endpoint="$2" ;;
    --ca) ca="$2" ;;
    --role-arn) role_arn="$2" ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift 2
done

[ -n "$env" ] || die "--env is required"
case " $EKS_SPOKE_ENVIRONMENTS " in
  *" $env "*) ;;
  *) die "--env '$env' must be one of: $EKS_SPOKE_ENVIRONMENTS" ;;
esac
[ -n "$cluster_name" ] || die "--cluster-name is required (terraform output -raw cluster_name)"
[ -n "$endpoint" ] || die "--endpoint is required (terraform output -raw cluster_endpoint)"
[ -n "$ca" ] || die "--ca is required (terraform output -raw cluster_certificate_authority_data)"
[ -n "$role_arn" ] || die "--role-arn is required (terraform output -raw argocd_manager_role_arn)"

# Same rule as terraform/envs/eks var.cluster_name.
printf '%s' "$cluster_name" | grep -qE '^[a-zA-Z][a-zA-Z0-9-]{0,24}$' \
  || die "--cluster-name '$cluster_name' is not a valid EKS cluster name of this project"
printf '%s' "$endpoint" | grep -qE '^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$' \
  || die "--endpoint must be an https:// host (no path, no credentials)"
printf '%s' "$ca" | grep -qE '^[A-Za-z0-9+/]+={0,2}$' \
  || die "--ca must be base64 (the cluster's certificate authority data)"
printf '%s' "$ca" | base64 -d 2>/dev/null | grep -q 'BEGIN CERTIFICATE' \
  || die "--ca does not decode to a PEM certificate"
# The role must be THIS environment's argocd-manager role (Phase 3.4.4a
# naming), so a uat role can never be registered as dev.
printf '%s' "$role_arn" | grep -qE "^arn:aws:iam::[0-9]{12}:role/eks-gitops-${env}-argocd-manager$" \
  || die "--role-arn must be arn:aws:iam::<12-digit account>:role/eks-gitops-${env}-argocd-manager"

name="${EKS_SPOKE_NAME_PREFIX}${env}"
cat <<EOF
# Rendered by lab/eks/spoke-cluster-secret.sh (Phase 3.4.4b). Apply on the
# hub only, in namespace argocd. No token: Argo CD assumes roleARN.
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    ${EKS_SPOKE_ENV_LABEL_KEY}: ${env}
    ${EKS_SPOKE_OWNER_LABEL_KEY}: ${EKS_SPOKE_OWNER_LABEL_VALUE}
type: Opaque
stringData:
  name: ${name}
  server: ${endpoint}
  namespaces: ${env}
  clusterResources: "false"
  config: |
    {"awsAuthConfig": {"clusterName": "${cluster_name}", "roleARN": "${role_arn}"}, "tlsClientConfig": {"insecure": false, "caData": "${ca}"}}
EOF
