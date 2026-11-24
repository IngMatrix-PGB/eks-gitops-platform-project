#!/bin/sh
# Phase 6.4a (ADR-0024): the in-cluster half of the sandbox session, after
# scripts/terraform/aws-session.sh applied every stack and wrote the
# kubeconfigs. Never calls terraform plan/apply; AWS is reached only
# through aws-session.sh (outputs, seed-secret) and the EKS kubeconfigs.
#
#   session-hub.sh up        spoke dev: namespace, Argo CD access, ESO;
#                            the dev secret's synthetic value; hub: Argo CD,
#                            the spoke's cluster Secret, the root Application
#   session-hub.sh teardown  removes what Argo CD deployed, then Argo CD's
#                            root, so destroy finds no Kubernetes-made AWS
#                            resource (load balancer, volume) behind
#
# Each kubectl/helm call names its kubeconfig and context explicitly:
# .local/kubeconfig-eks-hub (context eks-hub) or .local/kubeconfig-eks-dev
# (context eks-dev). Never pkubectl/phelm, never the global kubeconfig
# (ADR-0014). Backs `make eks-session-hub` / `make eks-session-teardown`.
set -eu

[ -f scripts/lab/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
# Constants and pure helpers only: LAB_CLUSTER=dev makes the libs load;
# nothing below uses pkubectl or phelm.
LAB_CLUSTER=dev
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh
# shellcheck source=../../scripts/eso/_lib.sh
. scripts/eso/_lib.sh

SESSION="bash scripts/terraform/aws-session.sh"
HUB_KC=".local/kubeconfig-eks-hub" HUB_CTX="eks-hub"
DEV_KC=".local/kubeconfig-eks-dev" DEV_CTX="eks-dev"
SPOKE="dev"
FIELD_MANAGER="eks-gitops-sandbox-session"
OWNER_KEY="eks-gitops-lab-lite.local/owner" OWNER_VALUE="eks-session"

fail() { echo "FAIL: $*" >&2; exit 1; }
hk() { KUBECONFIG="$HUB_KC" "$KUBECTL_BIN" --kubeconfig "$HUB_KC" --context "$HUB_CTX" "$@"; }
dk() { KUBECONFIG="$DEV_KC" "$KUBECTL_BIN" --kubeconfig "$DEV_KC" --context "$DEV_CTX" "$@"; }
eh() { # $1=kubeconfig $2=context, then helm arguments
  kc="$1" ctx="$2"; shift 2
  HELM_CONFIG_HOME=".local/helm/config" HELM_CACHE_HOME=".local/helm/cache" HELM_DATA_HOME=".local/helm/data" \
    KUBECONFIG="$kc" "$HELM_BIN" --kubeconfig "$kc" --kube-context "$ctx" "$@"
}
out() { $SESSION output "$1" "$2" | tr -d '"'; }

preflight() {
  for kc in "$HUB_KC" "$DEV_KC"; do [ -f "$kc" ] || fail "$kc missing - run 'make eks-session-kubeconfig' first"; done
  [ -x "$KUBECTL_BIN" ] && [ -x "$HELM_BIN" ] || fail "kubectl/helm missing - run 'make tools-install'"
  [ -f "$ARGOCD_CHART_TGZ" ] && [ -f "$ESO_CHART_TGZ" ] || fail "charts missing - run 'make charts-fetch'"
  hk get --raw /version >/dev/null 2>&1 || fail "the EKS hub does not answer through $HUB_KC"
  dk get --raw /version >/dev/null 2>&1 || fail "the EKS dev spoke does not answer through $DEV_KC"
  echo "OK: both EKS clusters answer through their own kubeconfigs"
}

spoke_up() {
  role="$(sed "s/SPOKE_NAMESPACE/${SPOKE}/g" platform/spoke-access/role.yaml)"
  cat <<EOF | dk apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${SPOKE}
  labels:
    ${OWNER_KEY}: ${OWNER_VALUE}
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.36
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.36
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.36
---
${role}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-manager
  namespace: ${SPOKE}
  labels:
    ${OWNER_KEY}: ${OWNER_VALUE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: argocd-manager
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: argocd-manager
EOF
  echo "OK: spoke: namespace '${SPOKE}' (PSA restricted), Role argocd-manager bound to the group argocd-manager (the hub's access entry)"

  # ESO: CRDs owned by no release, then one scoped release, as on a kind
  # spoke (lab/eso/install.sh). Its ServiceAccount eso-dev-external-secrets
  # is the one terraform/envs/identity gave a Pod Identity association.
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
  eh "$DEV_KC" "$DEV_CTX" template eso-crds "$ESO_CHART_TGZ" --namespace kube-system \
    --set installCRDs=true --set crds.createClusterExternalSecret=true --set crds.createClusterSecretStore=true \
    --set crds.createSecretStore=true --set crds.createClusterGenerator=true --set crds.createClusterPushSecret=true \
    --set crds.createPushSecret=true > "$work/full.yaml"
  eso_extract_crds "$work/full.yaml" > "$work/crds.yaml"
  dk apply --server-side --field-manager="$ESO_CRD_FIELD_MANAGER" -f "$work/crds.yaml" >/dev/null
  dk get namespace "eso-${SPOKE}" >/dev/null 2>&1 || dk create namespace "eso-${SPOKE}" >/dev/null
  eso_write_values "$SPOKE" true true "$work/eso-values.yaml"
  eh "$DEV_KC" "$DEV_CTX" upgrade --install "eso-${SPOKE}" "$ESO_CHART_TGZ" --namespace "eso-${SPOKE}" \
    -f "$work/eso-values.yaml" --wait --timeout 10m >/dev/null
  echo "OK: spoke: ESO CRDs and release eso-${SPOKE} (scopedNamespace=${SPOKE}) installed"
}

hub_up() {
  hk get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || hk create namespace "$ARGOCD_NAMESPACE" >/dev/null
  eh "$HUB_KC" "$HUB_CTX" upgrade --install "$ARGOCD_RELEASE_NAME" "$ARGOCD_CHART_TGZ" --namespace "$ARGOCD_NAMESPACE" \
    -f "$ARGOCD_VALUES_FILE" --wait --timeout 10m >/dev/null
  echo "OK: hub: Argo CD ${ARGOCD_CHART_APP_VERSION} installed from the pinned chart and $ARGOCD_VALUES_FILE"

  # Restart the two pods that hold the Pod Identity association, in case
  # they started before terraform's association existed.
  hk -n "$ARGOCD_NAMESPACE" rollout restart statefulset/argocd-application-controller deployment/argocd-server >/dev/null
  hk -n "$ARGOCD_NAMESPACE" rollout status statefulset/argocd-application-controller --timeout=5m >/dev/null

  sh lab/eks/spoke-cluster-secret.sh --env "$SPOKE" \
    --cluster-name "$(out eks-dev cluster_name)" \
    --endpoint "$(out eks-dev cluster_endpoint)" \
    --ca "$(out eks-dev cluster_certificate_authority_data)" \
    --role-arn "$(out eks-dev argocd_manager_role_arn)" \
    | hk apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  echo "OK: hub: cluster Secret spoke-${SPOKE} (awsAuthConfig, no token) applied"

  PROFILE=aws-eks EKS_SESSION_APPLY=1 \
    EKS_KUBECONFIG="$HUB_KC" EKS_CONTEXT="$HUB_CTX" \
    EKS_CLUSTER_NAME="$(out eks-platform cluster_name)" \
    EKS_REGION="$(out eks-platform cluster_endpoint | sed -n 's#^https://[^.]*\.[^.]*\.\([a-z0-9-]*\)\.eks\.amazonaws\.com$#\1#p')" \
    EKS_ENDPOINT="$(out eks-platform cluster_endpoint)" \
    REVISION="${REVISION:-main}" \
    sh lab/gitops/bootstrap.sh
}

teardown() {
  if hk -n "$ARGOCD_NAMESPACE" get application platform-bootstrap >/dev/null 2>&1; then
    # The root's finalizer cascades: ApplicationSets, then the generated
    # Applications, then what they deployed on the spoke.
    hk -n "$ARGOCD_NAMESPACE" delete application platform-bootstrap --wait=true --timeout=10m
  fi
  left="$(hk -n "$ARGOCD_NAMESPACE" get applications -o name 2>/dev/null | wc -l | tr -d ' ')"
  [ "$left" = "0" ] || fail "$left Application(s) still on the hub - check their finalizers before destroying"
  svc="$(dk get services -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | grep -c . || true)"
  [ "$svc" = "0" ] || fail "$svc LoadBalancer Service(s) on the spoke - their AWS load balancers would block the VPC destroy"
  pvc="$(dk get pvc -A -o name 2>/dev/null | grep -c . || true)"
  [ "$pvc" = "0" ] || fail "$pvc PersistentVolumeClaim(s) on the spoke - their volumes would outlive the cluster"
  echo "OK: teardown done - nothing Argo CD deployed is left; next: make eks-session-destroy STACK=identity-dev CONFIRM=yes"
}

case "${1:-}" in
  up)
    preflight
    spoke_up
    $SESSION seed-secret
    hub_up
    echo "session-hub: OK - next: make eks-session-verify"
    ;;
  teardown)
    preflight
    teardown
    ;;
  *) fail "usage: session-hub.sh up|teardown" ;;
esac
