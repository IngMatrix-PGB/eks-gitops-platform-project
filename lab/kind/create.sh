#!/bin/sh
# Creates ONLY the pinned lab-lite kind cluster - never staging/
# production/ApplicationSet/AppProject/Argo CD resources (see ADR-0001,
# ADR-0002). Exact idempotency contract: an existing cluster that
# matches the pinned baseline is a no-op (exit 0); an existing cluster
# under the same name that does not match is a failure (nonzero, no
# auto-delete/recreate). Backs `make lab-create` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
require_tools

check_cluster_identity || true

case "$IDENTITY_CASE" in
  match)
    echo "lab-create: no-op - $IDENTITY_DETAIL"
    exit 0
    ;;
  absent)
    : # proceed to create below
    ;;
  *)
    echo "FAIL: lab-create: $IDENTITY_DETAIL" >&2
    echo "      refusing to create, adopt, or overwrite - resolve manually before retrying." >&2
    exit 1
    ;;
esac

echo "lab-create: creating cluster '$PROJECT_CLUSTER_NAME' ..."
"$KIND_BIN" create cluster \
  --name "$PROJECT_CLUSTER_NAME" \
  --config lab/kind/lab-lite.kind.yaml \
  --kubeconfig "$PROJECT_KUBECONFIG"

if ! check_cluster_identity || [ "$IDENTITY_CASE" != "match" ]; then
  echo "FAIL: lab-create: cluster created but failed post-create identity validation - $IDENTITY_DETAIL" >&2
  exit 1
fi

echo "lab-create: success - $IDENTITY_DETAIL"
