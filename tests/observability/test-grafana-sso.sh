#!/bin/sh
# Phase 4c (ADR-0025): Grafana's sign-in through Keycloak, live on the
# lab-multicluster hub. Backs `make obs-test-sso` (LAB_CLUSTER=hub).
# Read-only apart from the Grafana users the first sign-in creates and
# one local admin sign-in.
#
# It runs the real browser flow with curl, no browser and no /etc/hosts
# change: Grafana's /login/generic_oauth -> Keycloak's login form (the
# user's password posted from .local/identity/<user>) -> Grafana's
# callback, which exchanges the code with Keycloak inside the cluster ->
# a Grafana session cookie. curl's --connect-to sends the two public
# names (localhost:3000 and the issuer host) to the port-forwards.
#   - admin-user: org role Admin, holds datasources:write;
#   - auditor-user, dev-user, uat-user: Viewer, no datasources:write
#     (Grafana 13 lets a Viewer read data sources, so the write
#     permission is the line between the roles);
#   - nogroup-user: refused, no session (401);
#   - no cookie: 401;
#   - break-glass: the local admin still signs in (200), and that sign-in
#     raises GrafanaLocalAdminLogin in Alertmanager (it pages: this test
#     is the reason it fires).
# Passwords and session cookies live in files under a mktemp directory,
# never on argv, never printed.
set -eu
[ -f scripts/lab/_lib.sh ] || { echo "FAIL: must be run from the repository root" >&2; exit 1; }
[ "${LAB_CLUSTER:-}" = hub ] || { echo "FAIL: Grafana and Keycloak run on the hub - LAB_CLUSTER=hub" >&2; exit 1; }
. scripts/lab/_lib.sh
require_repo_root
. scripts/observability/_lib.sh
. scripts/identity/_lib.sh
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }

work="$(mktemp -d)"
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT INT TERM
umask 077
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

G_PORT="${G_PORT:-13000}" KC_PORT="${KC_PORT:-18081}"
forward() { # <namespace> <service> <local>:<remote> <probe-url>
  KUBECONFIG="$PROJECT_KUBECONFIG" "$KUBECTL_BIN" --kubeconfig "$PROJECT_KUBECONFIG" \
    -n "$1" port-forward "service/$2" "$3" >/dev/null 2>&1 &
  pids="$pids $!"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do curl -sS -o /dev/null "$4" 2>/dev/null && return 0; sleep 1; done
  echo "FAIL: port-forward to $1/$2 did not open" >&2; exit 1
}
forward "$OBS_NAMESPACE" "$OBS_GRAFANA_RELEASE" "$G_PORT:80" "http://127.0.0.1:$G_PORT/api/health"
forward "$IDP_NAMESPACE" "$IDP_SERVICE" "$KC_PORT:8080" "http://127.0.0.1:$KC_PORT/realms/$IDP_REALM"
AM_PORT="${AM_PORT:-19095}"
forward "$OBS_NAMESPACE" obs-alertmanager "$AM_PORT:9093" "http://127.0.0.1:$AM_PORT/-/ready"

g_host="${OBS_GRAFANA_ROOT_URL#http://}"
kc_host="${IDP_ISSUER#http://}"; kc_host="${kc_host%%/*}"
c() { # curl with the cookie jar of user $U, both names routed to the port-forwards
  curl -sS -b "$work/jar.$U" -c "$work/jar.$U" \
    --connect-to "$g_host:127.0.0.1:$G_PORT" --connect-to "$kc_host:127.0.0.1:$KC_PORT" "$@"
}

pkubectl -n "$OBS_NAMESPACE" get secret "$IDP_GRAFANA_SECRET" >/dev/null 2>&1 \
  && ok "Secret $OBS_NAMESPACE/$IDP_GRAFANA_SECRET present" || bad "Secret $OBS_NAMESPACE/$IDP_GRAFANA_SECRET missing - make idp-install"
code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$G_PORT/api/datasources")"
[ "$code" = 401 ] && ok "no session: data sources -> 401" || bad "no session: data sources -> $code (want 401)"

# signin <user> - runs the flow; prints the final Grafana path it lands on.
signin() {
  U="$1"; : > "$work/jar.$U"
  loc="$(c -o /dev/null -w '%{redirect_url}' "$OBS_GRAFANA_ROOT_URL/login/generic_oauth")"
  case "$loc" in "$IDP_ISSUER/protocol/openid-connect/auth?"*) : ;; *) echo "no-redirect-to-keycloak"; return 0 ;; esac
  c -o "$work/form.html" "$loc"
  action="$(python3 -I - "$work/form.html" <<'PY'
import html, re, sys
m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', open(sys.argv[1]).read())
print(html.unescape(m.group(1)) if m else "")
PY
)"
  [ -n "$action" ] || { echo "no-login-form"; return 0; }
  cb="$(c -o /dev/null -w '%{redirect_url}' -X POST --data-urlencode "username=$U" \
    --data-urlencode "password@$IDP_LOCAL_DIR/$U" --data-urlencode credentialId= "$action")"
  case "$cb" in "$OBS_GRAFANA_ROOT_URL/login/generic_oauth?"*) : ;; *) echo "keycloak-refused"; return 0 ;; esac
  end="$(c -o /dev/null -w '%{redirect_url}' "$cb")"
  echo "${end#"$OBS_GRAFANA_ROOT_URL"}"
}
# role <user> - org role of the session, or "none".
role() {
  U="$1"; c -o "$work/orgs" "$OBS_GRAFANA_ROOT_URL/api/user/orgs" >/dev/null 2>&1 || true
  jq -r '.[0].role // "none"' "$work/orgs" 2>/dev/null || echo none
}
# dsw <user> - "write" when the session holds datasources:write, "read-only"
# when it does not, or the HTTP code when there is no session.
dsw() {
  U="$1"; code="$(c -o "$work/perms" -w '%{http_code}' "$OBS_GRAFANA_ROOT_URL/api/access-control/user/permissions")"
  [ "$code" = 200 ] || { echo "$code"; return 0; }
  jq -e 'has("datasources:write")' "$work/perms" >/dev/null && echo write || echo read-only
}

while IFS='|' read -r u want_role want_ds; do
  [ -n "$u" ] || continue
  [ -f "$IDP_LOCAL_DIR/$u" ] || { bad "$IDP_LOCAL_DIR/$u missing - make idp-install"; continue; }
  landed="$(signin "$u")"
  r="$(role "$u")"; d="$(dsw "$u")"
  if [ "$r" = "$want_role" ] && [ "$d" = "$want_ds" ] && [ "$want_role" = none ]; then
    ok "$u: Keycloak accepted the password, Grafana refused the sign-in (back on '${landed}', no session: $d)"
  elif [ "$r" = "$want_role" ] && [ "$d" = "$want_ds" ]; then
    ok "$u: signed in through Keycloak (landed on '${landed}'), role $r, data sources $d"
  else
    bad "$u: landed on '${landed}', role '$r' (want $want_role), data sources '$d' (want $want_ds)"
  fi
done <<T
admin-user|Admin|write
auditor-user|Viewer|read-only
dev-user|Viewer|read-only
uat-user|Viewer|read-only
nogroup-user|none|401
T

# Break-glass: the local admin, from its Secret, through the login API.
obs_secret_key pkubectl "$OBS_SECRET_GRAFANA_ADMIN" admin-password \
  | jq -Rs --arg u "$(obs_secret_key pkubectl "$OBS_SECRET_GRAFANA_ADMIN" admin-user)" '{user: $u, password: .}' > "$work/login.json"
code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary "@$work/login.json" "http://127.0.0.1:$G_PORT/login")"
rm -f "$work/login.json"
[ "$code" = 200 ] && ok "break-glass: the local admin still signs in (200)" || bad "break-glass: local admin sign-in -> $code (want 200)"
i=0; seen=0
while [ "$i" -lt 180 ]; do
  if curl -sS -G "http://127.0.0.1:$AM_PORT/api/v2/alerts" --data-urlencode active=true \
       --data-urlencode 'filter=alertname="GrafanaLocalAdminLogin"' | jq -e 'length > 0' >/dev/null 2>&1; then seen=1; break; fi
  sleep 5; i=$((i + 5))
done
[ "$seen" = 1 ] && ok "the local sign-in raised GrafanaLocalAdminLogin (Prometheus -> Alertmanager)" || bad "GrafanaLocalAdminLogin not active within 3 minutes"

[ "$fail" -eq 0 ] || { echo "obs-test-sso: FAILED" >&2; exit 1; }
echo "obs-test-sso: OK"
exit 0
