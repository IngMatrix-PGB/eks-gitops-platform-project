#!/bin/sh
# Shared Helm helpers for scripts/argocd/_lib.sh and scripts/eso/_lib.sh.
# POSIX-compatible shell only - no bashisms. Sourced, never executed
# directly. Extracted verbatim (Phase 3.2.1, byte-for-byte unchanged)
# from the two domain libs, which had defined these identically -
# consolidated here so a future change only needs to happen once.
#
# Requires the caller to have already set, before sourcing this file:
#   HELM_BIN            - path to the project-local helm binary
#                          (each domain lib defines this itself, same
#                          value: ".tools/bin/helm")
#   PROJECT_KUBECONFIG   - set by scripts/lab/_lib.sh, which every
#                          caller of this file already sources first
#                          (see each domain lib's own header comment).

require_helm() {
  if [ ! -x "$HELM_BIN" ]; then
    echo "FAIL: $HELM_BIN not found or not executable - run 'make tools-install' first" >&2
    exit 1
  fi
}

# Explicit helm wrapper: project-local binary, isolated config/cache/data
# under .local/helm/, project-local kubeconfig - never global state.
phelm() {
  HELM_CONFIG_HOME=".local/helm/config" \
  HELM_CACHE_HOME=".local/helm/cache" \
  HELM_DATA_HOME=".local/helm/data" \
  HELM_REGISTRY_CONFIG=".local/helm/config/registry/config.json" \
  KUBECONFIG="$PROJECT_KUBECONFIG" \
    "$HELM_BIN" --kubeconfig "$PROJECT_KUBECONFIG" "$@"
}
