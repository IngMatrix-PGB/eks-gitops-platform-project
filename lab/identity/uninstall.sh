#!/bin/sh
# Phase 4a (ADR-0025): removes the lab identity provider from the hub
# (namespace keycloak, its Secrets included) and the local copies of the
# test-user passwords. Needs CONFIRM=yes. Backs `make idp-uninstall`.
set -eu
[ -f scripts/lab/_lib.sh ] || { echo "FAIL: must be run from the repository root" >&2; exit 1; }
[ "${LAB_CLUSTER:-}" = hub ] || { echo "FAIL: LAB_CLUSTER=hub" >&2; exit 1; }
[ "${CONFIRM:-}" = yes ] || { echo "FAIL: idp-uninstall deletes namespace keycloak and its generated secrets - rerun with CONFIRM=yes" >&2; exit 1; }
. scripts/lab/_lib.sh
. scripts/identity/_lib.sh
pkubectl delete namespace "$IDP_NAMESPACE" --ignore-not-found --wait=true --timeout=5m
rm -rf "$IDP_LOCAL_DIR"
echo "idp-uninstall: OK"
