#!/bin/sh
# Phase 4a (ADR-0025): fail-closed, idempotent install of Keycloak, the
# lab identity provider, on the lab-multicluster hub. Backs
# `make idp-install` (LAB_CLUSTER=hub only).
#
#   - Secrets keycloak-bootstrap-admin and keycloak-realm-secrets: every
#     password and client secret generated once (32 random characters) and
#     kept on re-runs; a key missing from an older Secret is added.
#   - The realm from Git (platform/identity/realm-platform.json, only
#     ${KC_*} placeholders) as a ConfigMap; Keycloak resolves the
#     placeholders from the Secret at import.
#   - The manifest, server-side applied; the pod restarts only when the
#     realm, image or manifest changed.
#   - Each test user's password copied to .local/identity/<user> (mode
#     600) for the token tests. Nothing secret is printed or put on argv.
# A first install refuses with less free Docker memory than IDP_MIB
# (IDP_SKIP_MEMORY_CHECK=1 overrides, printed).
set -eu

[ -f scripts/lab/_lib.sh ] || { echo "FAIL: must be run from the repository root" >&2; exit 1; }
[ "${LAB_CLUSTER:-}" = hub ] || { echo "FAIL: the identity provider runs on the hub only - LAB_CLUSTER=hub" >&2; exit 1; }
. scripts/lab/_lib.sh
require_repo_root
. lab/multicluster/_lib.sh
. scripts/identity/_lib.sh
require_tools
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

sh lab/identity/render.sh >/dev/null || { echo "FAIL: the offline identity checks fail - run 'make check-identity'" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
umask 077

if ! pkubectl -n "$IDP_NAMESPACE" get deployment "$IDP_DEPLOYMENT" >/dev/null 2>&1; then
  free_mib="$(lab_mc_docker_free_mib)" || { echo "FAIL: could not read Docker memory" >&2; exit 1; }
  if [ "${IDP_SKIP_MEMORY_CHECK:-}" = "1" ]; then
    echo "idp-install: WARNING - memory check skipped by IDP_SKIP_MEMORY_CHECK=1 (~${free_mib} MiB free, floor ${IDP_MIB} MiB)"
  elif [ "$free_mib" -lt "$IDP_MIB" ]; then
    echo "FAIL: idp-install: Docker has ~${free_mib} MiB free; Keycloak needs ~${IDP_MIB} MiB. Nothing was installed." >&2
    exit 1
  else
    echo "OK: memory check - ~${free_mib} MiB free, floor ${IDP_MIB} MiB"
  fi
fi

idp_render_manifest "$work/keycloak.yaml"
# The namespace first (the Secrets live in it), from the same manifest.
.tools/bin/yq 'select(.kind == "Namespace")' "$work/keycloak.yaml" \
  | pkubectl apply --server-side --field-manager=identity-bootstrap -f - >/dev/null

# ensure_keys <secret> <key>... - keeps existing values, generates missing ones.
ensure_keys() {
  ek_secret="$1"; shift
  mkdir -p "$work/$ek_secret"; ek_new=0
  for ek_key in "$@"; do
    if idp_secret_key pkubectl "$ek_secret" "$ek_key" > "$work/$ek_secret/$ek_key" 2>/dev/null; then :; else
      idp_random_secret > "$work/$ek_secret/$ek_key"; ek_new=$((ek_new + 1))
    fi
    [ -s "$work/$ek_secret/$ek_key" ] || { echo "FAIL: empty value for $ek_secret/$ek_key" >&2; exit 1; }
  done
  if [ "$ek_new" -gt 0 ]; then
    pkubectl -n "$IDP_NAMESPACE" create secret generic "$ek_secret" --from-file="$work/$ek_secret" --dry-run=client -o yaml \
      | pkubectl apply -f - >/dev/null
    echo "OK: Secret $ek_secret: $ek_new value(s) generated, the rest kept"
  else
    echo "OK: Secret $ek_secret already complete - kept"
  fi
}
# The bootstrap admin's user name is fixed; its password is generated.
if ! idp_secret_key pkubectl "$IDP_SECRET_BOOTSTRAP" username >/dev/null 2>&1; then
  mkdir -p "$work/$IDP_SECRET_BOOTSTRAP"; printf 'kc-bootstrap' > "$work/$IDP_SECRET_BOOTSTRAP/username"
  idp_random_secret > "$work/$IDP_SECRET_BOOTSTRAP/password"
  pkubectl -n "$IDP_NAMESPACE" create secret generic "$IDP_SECRET_BOOTSTRAP" --from-file="$work/$IDP_SECRET_BOOTSTRAP" --dry-run=client -o yaml \
    | pkubectl apply -f - >/dev/null
  echo "OK: Secret $IDP_SECRET_BOOTSTRAP generated"
else
  echo "OK: Secret $IDP_SECRET_BOOTSTRAP already present - kept"
fi
# shellcheck disable=SC2046
ensure_keys "$IDP_SECRET_REALM" $(idp_placeholder_vars)

mkdir -p "$IDP_LOCAL_DIR"; chmod 700 "$IDP_LOCAL_DIR"
printf '%s\n' "$IDP_USERS" | while IFS='|' read -r u _g var; do
  [ -n "$u" ] || continue
  idp_secret_key pkubectl "$IDP_SECRET_REALM" "$var" > "$IDP_LOCAL_DIR/$u"
  chmod 600 "$IDP_LOCAL_DIR/$u"
done
echo "OK: test-user passwords copied to $IDP_LOCAL_DIR/ (mode 600, never printed)"

pkubectl -n "$IDP_NAMESPACE" create configmap "$IDP_REALM_CM" --from-file=realm-platform.json="$IDP_REALM_FILE" \
  --dry-run=client -o yaml | pkubectl apply --server-side --field-manager=identity-bootstrap -f - >/dev/null
pkubectl apply --server-side --field-manager=identity-bootstrap -f "$work/keycloak.yaml" >/dev/null
echo "idp-install: waiting for Keycloak to be Ready (first start imports the realm, ~1-3 min) ..."
pkubectl -n "$IDP_NAMESPACE" rollout status deployment/"$IDP_DEPLOYMENT" --timeout=10m >/dev/null \
  || { echo "FAIL: Keycloak did not become Ready - pkubectl -n $IDP_NAMESPACE logs deploy/$IDP_DEPLOYMENT" >&2; exit 1; }
echo "OK: Keycloak Ready (image ${IDP_IMAGE%%@*}, issuer $IDP_ISSUER)"
echo "idp-install: OK - next: make idp-status"
