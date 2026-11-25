#!/bin/sh
# Phase 4a (ADR-0025): constants for the lab identity provider. Sourced,
# never executed; POSIX sh. Keycloak is the reproducible IdP for the local
# lab only (ADR-0005), on the lab-multicluster hub.

IDP_NAMESPACE="keycloak"
IDP_DEPLOYMENT="keycloak"
IDP_SERVICE="keycloak"
IDP_MANIFEST="platform/identity/keycloak.yaml"
IDP_REALM_FILE="platform/identity/realm-platform.json"
IDP_REALM="platform"
IDP_REALM_CM="keycloak-realm-platform"
# Keycloak 26.8.1 (2026-10-31), multi-arch index digest.
IDP_IMAGE="quay.io/keycloak/keycloak:26.8.1@sha256:3f3c5f8e03c614774b4bd9173b88391fefa4153bfc010d8012d59ad825377332"
# One issuer for every caller: in-cluster clients (Argo CD, Grafana) and
# the operator's port-forward both see this exact URL (ADR-0025).
IDP_ISSUER="http://keycloak.keycloak.svc.cluster.local:8080/realms/platform"
# Generated once by lab/identity/install.sh, kept on re-runs, never in Git.
IDP_SECRET_BOOTSTRAP="keycloak-bootstrap-admin"
IDP_SECRET_REALM="keycloak-realm-secrets"
# The realm's test users, one per role (TAD "Human Identity and SSO"):
# user|group (empty = no group)|env var holding its password.
IDP_USERS="admin-user|platform-admins|KC_PW_ADMIN_USER
dev-user|developers-dev|KC_PW_DEV_USER
uat-user|developers-uat|KC_PW_UAT_USER
auditor-user|auditors|KC_PW_AUDITOR_USER
nogroup-user||KC_PW_NOGROUP_USER"
# Confidential clients: client id|env var holding its secret.
IDP_CLIENTS="argocd|KC_CLIENT_SECRET_ARGOCD
grafana|KC_CLIENT_SECRET_GRAFANA"
# Operator-side copies of the test users' passwords (mode 600), for the
# token tests of 4a and the role matrix of 4b.
IDP_LOCAL_DIR=".local/identity"
# Phase 4b: where Argo CD reads its client secret (oidc.config in
# lab/argocd/values-lab.yaml: $argocd-oidc:clientSecret).
IDP_ARGOCD_NAMESPACE="argocd"
IDP_ARGOCD_SECRET="argocd-oidc"
# Phase 4c: where Grafana reads its client secret (envFromSecrets in
# scripts/observability/_lib.sh; must equal OBS_SECRET_GRAFANA_OIDC).
IDP_GRAFANA_NAMESPACE="monitoring"
IDP_GRAFANA_DEPLOYMENT="obs-grafana"
IDP_GRAFANA_SECRET="obs-grafana-oidc"
# First install refuses with less free Docker memory than this.
IDP_MIB=800

# idp_render_manifest <out-file> - the manifest with the pinned image, the
# issuer host and the realm file's SHA-256 substituted.
idp_render_manifest() {
  irm_host="${IDP_ISSUER#http://}"; irm_host="${irm_host%%:*}"
  irm_sha="$(shasum -a 256 "$IDP_REALM_FILE" | awk '{print $1}')"
  sed -e "s#__IDP_IMAGE__#${IDP_IMAGE}#" \
      -e "s#__IDP_ISSUER_HOST__#${irm_host}#" \
      -e "s#__IDP_REALM_SHA__#${irm_sha}#" \
      "$IDP_MANIFEST" > "$1"
}

idp_random_secret() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

# idp_secret_key <kubectl-fn> <secret> <key> - decoded value, or exit 1.
idp_secret_key() {
  isk_v="$("$1" -n "$IDP_NAMESPACE" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null)" || return 1
  [ -n "$isk_v" ] || return 1
  printf '%s' "$isk_v" | base64 -d
}

# Every env var the realm file must reference: one per user, one per client.
idp_placeholder_vars() {
  printf '%s\n' "$IDP_USERS" | awk -F'|' 'NF{print $3}'
  printf '%s\n' "$IDP_CLIENTS" | awk -F'|' 'NF{print $2}'
}
