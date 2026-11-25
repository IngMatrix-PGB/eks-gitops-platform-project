#!/bin/sh
# Phase 4c (ADR-0025): offline checks of Grafana's sign-in through the lab
# Keycloak, on the values scripts/observability/_lib.sh generates. No
# cluster, no network. Backs `make check-grafana-sso` (in validate).
#   - anonymous off; generic OAuth on, client grafana (in the realm), PKCE;
#   - auth, token and userinfo URLs on the lab issuer;
#   - no client secret in the values: it comes only from the optional
#     Secret idp-install writes (same name, namespace and Deployment on
#     both sides);
#   - root_url's callback is a redirect the realm's grafana client allows;
#   - roles: exactly the expression built from the realm's groups
#     (platform-admins Admin; auditors and developers-<env> Viewer;
#     anything else refused by role_attribute_strict), no Grafana server
#     admin from SSO, role synced on every sign-in.
set -eu
[ -f scripts/observability/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/observability/_lib.sh
. scripts/identity/_lib.sh
YQ="${YQ_BIN:-.tools/bin/yq}"
[ -x "$YQ" ] || { echo "FAIL: $YQ missing - run 'make tools-install'" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
obs_write_grafana_values "$work/values.yaml"
"$YQ" -o=json '.' "$work/values.yaml" > "$work/values.json"
groups="$(printf '%s\n' "$IDP_USERS" | awk -F'|' 'NF && $2 != "" {print $2}' | sort -u | tr '\n' ' ')"

python3 -I - "$work/values.json" "$IDP_REALM_FILE" "$IDP_ISSUER" "$OBS_SECRET_GRAFANA_OIDC" "$IDP_GRAFANA_SECRET" \
  "$OBS_NAMESPACE" "$IDP_GRAFANA_NAMESPACE" "$OBS_GRAFANA_RELEASE" "$IDP_GRAFANA_DEPLOYMENT" "$groups" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); realm = json.load(open(sys.argv[2])); issuer = sys.argv[3]
obs_secret, idp_secret, obs_ns, idp_ns, obs_dep, idp_dep = sys.argv[4:10]
groups = sorted(sys.argv[10].split())
ini = v.get("grafana.ini") or {}; o = ini.get("auth.generic_oauth") or {}
fail = 0
def ok(m): print("OK: " + m); return True
def bad(m):
    global fail; fail = 1; print("FAIL: " + m, file=sys.stderr)
def truthy(x): return str(x).lower() == "true"

not truthy((ini.get("auth.anonymous") or {}).get("enabled")) and ok("anonymous access off") or bad("anonymous access is on")
truthy(o.get("enabled")) and ok("generic OAuth on") or bad("auth.generic_oauth.enabled is not true")
client = next((c for c in realm.get("clients", []) if c.get("clientId") == o.get("client_id")), None)
o.get("client_id") == "grafana" and client and ok("client grafana, defined in the realm") or bad(f"client_id {o.get('client_id')!r} is not the realm's grafana client")
truthy(o.get("use_pkce")) and ok("PKCE on") or bad("use_pkce is not true")
want = {"auth_url": "/protocol/openid-connect/auth", "token_url": "/protocol/openid-connect/token", "api_url": "/protocol/openid-connect/userinfo"}
for k, suffix in want.items():
    if o.get(k) != issuer + suffix: bad(f"{k} {o.get(k)!r}, want {issuer + suffix!r}")
all(o.get(k) == issuer + s for k, s in want.items()) and ok(f"auth, token and userinfo URLs on the lab issuer ({issuer})")
secret_keys = [k for k in o if "secret" in k.lower()]
not secret_keys and ok("no client secret in the values") or bad(f"secret in the values: {secret_keys}")
efs = v.get("envFromSecrets") or []
(any(e.get("name") == obs_secret and e.get("optional") is True for e in efs) and obs_secret == idp_secret
 and obs_ns == idp_ns and obs_dep == idp_dep) \
    and ok(f"client secret only from the optional Secret {obs_ns}/{obs_secret}, the one idp-install writes") \
    or bad(f"envFromSecrets {efs} / idp-install target {idp_ns}/{idp_secret} ({idp_dep}) disagree with {obs_ns}/{obs_secret} ({obs_dep})")
root = (ini.get("server") or {}).get("root_url", "")
cb = root.rstrip("/") + "/login/generic_oauth"
root.startswith("http://localhost:") and client and cb in client.get("redirectUris", []) \
    and ok(f"callback {cb} is a redirect the realm allows") or bad(f"root_url {root!r}: callback {cb!r} not in the realm's grafana redirectUris")
viewers = [g for g in groups if g == "auditors" or g.startswith("developers-")]
other = [g for g in groups if g not in viewers and g != "platform-admins"]
if other: bad(f"realm groups with no Grafana role in this design: {other}")
expr = ("contains(groups[*], 'platform-admins') && 'Admin' || ("
        + " || ".join(f"contains(groups[*], '{g}')" for g in viewers) + ") && 'Viewer' || ''")
o.get("role_attribute_path") == expr and ok("role expression built from the realm's groups (Admin: platform-admins; Viewer: " + ", ".join(viewers) + ")") \
    or bad(f"role_attribute_path {o.get('role_attribute_path')!r}, want {expr!r}")
truthy(o.get("role_attribute_strict")) and ok("a user with no mapped group is refused") or bad("role_attribute_strict is not true")
not truthy(o.get("allow_assign_grafana_admin")) and ok("SSO never makes a Grafana server admin") or bad("allow_assign_grafana_admin is on")
not truthy(o.get("skip_org_role_sync")) and ok("role synced on every sign-in") or bad("skip_org_role_sync is on")
sys.exit(fail)
PY
echo "check-grafana-sso: OK"
