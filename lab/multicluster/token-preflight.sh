#!/bin/sh
# Preflight for the commands that need the spokes (gitops-switch-revision
# on the hub, mc-test-e2e, argocd-test-sso, the backup drills): rotates
# any spoke token with less than 2 hours left, so the command does not
# time out against an expired credential. A no-op when there is no
# lab-multicluster hub kubeconfig. LAB_MC_SKIP_TOKEN_PREFLIGHT=1 skips it.
set -eu
if [ "${LAB_MC_SKIP_TOKEN_PREFLIGHT:-}" = "1" ]; then
  echo "token-preflight: skipped (LAB_MC_SKIP_TOKEN_PREFLIGHT=1)"
  exit 0
fi
[ -f .local/kubeconfig-hub ] || exit 0
MIN_HOURS=2 sh lab/multicluster/spoke-rotate.sh | sed 's/^/token-preflight: /'
