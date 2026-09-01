#!/bin/sh
# Foreground port-forward to the Argo CD server Service, for local UI/CLI
# access only. Never runs in the background, never touches any other
# namespace or cluster. Ctrl-C to stop. Backs `make argocd-port-forward`.
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

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

if ! pkubectl -n "$ARGOCD_NAMESPACE" get svc argocd-server >/dev/null 2>&1; then
  echo "FAIL: Service 'argocd-server' not found in namespace '$ARGOCD_NAMESPACE' - run 'make argocd-install' first" >&2
  exit 1
fi

echo "port-forward: https://localhost:8443 -> svc/argocd-server:443 (namespace $ARGOCD_NAMESPACE)"
echo "port-forward: press Ctrl-C to stop"
exec "$KUBECTL_BIN" --kubeconfig "$PROJECT_KUBECONFIG" -n "$ARGOCD_NAMESPACE" \
  port-forward svc/argocd-server 8443:443
