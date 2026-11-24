#!/bin/sh
# Phase 4b (ADR-0025): shared helpers for tests/argocd/test-sso-rbac.sh and
# test-breakglass.sh. Sourced after scripts/lab/_lib.sh,
# scripts/argocd/_lib.sh and scripts/identity/_lib.sh, with $work set.
# Two port-forwards (Keycloak, the Argo CD API server), started with the
# kubectl binary itself so cleanup stops exactly them. No secret is
# printed or put on argv: client secret, passwords and tokens live in
# files under $work (mode 600).

SSO_KC_PORT="${SSO_KC_PORT:-18080}"
SSO_API_PORT="${SSO_API_PORT:-18443}"
sso_pids=""

sso_cleanup() {
  for p in $sso_pids; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}

sso_forward() { # <namespace> <service> <local>:<remote> <probe-url>
  KUBECONFIG="$PROJECT_KUBECONFIG" "$KUBECTL_BIN" --kubeconfig "$PROJECT_KUBECONFIG" \
    -n "$1" port-forward "service/$2" "$3" >/dev/null 2>&1 &
  sso_pids="$sso_pids $!"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    curl -ksS -o /dev/null "$4" 2>/dev/null && return 0
    sleep 1
  done
  echo "FAIL: port-forward to $1/$2 did not open" >&2; return 1
}

sso_up() {
  umask 077
  sso_forward "$IDP_NAMESPACE" "$IDP_SERVICE" "$SSO_KC_PORT:8080" "http://127.0.0.1:$SSO_KC_PORT/realms/$IDP_REALM"
  sso_forward "$ARGOCD_NAMESPACE" argocd-server "$SSO_API_PORT:443" "https://127.0.0.1:$SSO_API_PORT/healthz"
  idp_secret_key pkubectl "$IDP_SECRET_REALM" KC_CLIENT_SECRET_ARGOCD > "$work/client-secret" \
    || { echo "FAIL: no argocd client secret - make idp-install" >&2; return 1; }
}

# sso_token <user> - writes the user's id_token to $work/tok.<user>.
sso_token() {
  [ -f "$IDP_LOCAL_DIR/$1" ] || { echo "FAIL: $IDP_LOCAL_DIR/$1 missing - make idp-install" >&2; return 1; }
  curl -sS -o "$work/resp" -X POST "http://127.0.0.1:$SSO_KC_PORT/realms/$IDP_REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=argocd \
    --data-urlencode "client_secret@$work/client-secret" --data-urlencode scope=openid \
    --data-urlencode "username=$1" --data-urlencode "password@$IDP_LOCAL_DIR/$1"
  jq -r '.id_token // empty' "$work/resp" > "$work/tok.$1"
  [ -s "$work/tok.$1" ] || { echo "FAIL: $1: no id_token from Keycloak" >&2; return 1; }
}

# sso_api <token-file> <METHOD> <path> [json-body] - prints the HTTP code;
# the body is left in $work/body. The token goes through a curl config
# file, never argv.
sso_api() {
  { printf 'header = "Authorization: Bearer '; tr -d '\n' < "$1"; printf '"\n'; } > "$work/auth.cfg"
  if [ -n "${4:-}" ]; then
    curl -ksS -K "$work/auth.cfg" -o "$work/body" -w '%{http_code}' -X "$2" \
      -H 'Content-Type: application/json' --data "$4" "https://127.0.0.1:$SSO_API_PORT$3"
  else
    curl -ksS -K "$work/auth.cfg" -o "$work/body" -w '%{http_code}' -X "$2" "https://127.0.0.1:$SSO_API_PORT$3"
  fi
}

# sso_admin_login - POSTs the local admin's password (from
# argocd-initial-admin-secret) to /api/v1/session; prints the HTTP code
# and leaves a token, if any, in $work/tok.admin.
sso_admin_login() {
  pkubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \
    | base64 -d | jq -Rs '{username: "admin", password: .}' > "$work/login.json"
  code="$(curl -ksS -o "$work/body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data-binary "@$work/login.json" "https://127.0.0.1:$SSO_API_PORT/api/v1/session")"
  rm -f "$work/login.json"
  jq -r '.token // empty' "$work/body" > "$work/tok.admin" 2>/dev/null || : > "$work/tok.admin"
  echo "$code"
}
