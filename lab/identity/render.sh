#!/bin/sh
# Phase 4a (ADR-0025): offline checks of the lab identity provider. No
# cluster, no network. Backs `make check-identity` (in validate) and runs
# before every `make idp-install`.
#   - image pinned by digest, and the one in scripts/identity/_lib.sh;
#   - Pod Security restricted on the namespace; non-root, no privilege
#     escalation, all capabilities dropped, no ServiceAccount token;
#   - the issuer host is the in-cluster Service DNS name;
#   - the realm holds no secret: every client "secret" and every
#     credential "value" is exactly a ${KC_*} placeholder, and the
#     placeholders, users, groups and clients equal scripts/identity/
#     _lib.sh's tables;
#   - redirect URIs only on localhost.
set -eu
[ -f scripts/identity/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/identity/_lib.sh
YQ="${YQ_BIN:-.tools/bin/yq}"
[ -x "$YQ" ] || { echo "FAIL: $YQ missing - run 'make tools-install'" >&2; exit 1; }
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
idp_render_manifest "$work/m.yaml"
grep -q '__IDP_' "$work/m.yaml" && bad "a placeholder was not substituted in $IDP_MANIFEST"

printf '%s' "$IDP_IMAGE" | grep -qE '^quay\.io/keycloak/keycloak:[0-9.]+@sha256:[0-9a-f]{64}$' \
  && ok "image pinned by tag and digest ($IDP_IMAGE)" || bad "IDP_IMAGE is not quay.io/keycloak/keycloak:<version>@sha256:<digest>"
imgs="$("$YQ" -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].image' "$work/m.yaml")"
[ "$imgs" = "$IDP_IMAGE" ] && ok "the Deployment runs exactly IDP_IMAGE" || bad "Deployment images: $imgs"

for m in enforce audit warn; do
  [ "$("$YQ" -N "select(.kind == \"Namespace\") | .metadata.labels.\"pod-security.kubernetes.io/$m\"" "$work/m.yaml")" = restricted ] \
    || bad "namespace label pod-security.kubernetes.io/$m is not restricted"
done
dep() { "$YQ" -N "select(.kind == \"Deployment\") | $1" "$work/m.yaml"; }
[ "$(dep '.spec.template.spec.securityContext.runAsNonRoot')" = true ] || bad "runAsNonRoot is not true"
[ "$(dep '.spec.template.spec.automountServiceAccountToken')" = false ] || bad "the pod mounts a ServiceAccount token"
[ "$(dep '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation')" = false ] || bad "allowPrivilegeEscalation is not false"
[ "$(dep '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]')" = ALL ] || bad "capabilities are not all dropped"
[ "$(dep '.spec.template.spec.securityContext.seccompProfile.type')" = RuntimeDefault ] || bad "seccompProfile is not RuntimeDefault"
[ "$fail" -eq 0 ] && ok "namespace restricted; pod non-root, no escalation, ALL dropped, RuntimeDefault, no token"

host="$(dep '.spec.template.spec.containers[0].env[] | select(.name == "KC_HOSTNAME") | .value')"
[ "$host/realms/$IDP_REALM" = "$IDP_ISSUER" ] && ok "issuer $IDP_ISSUER (in-cluster Service DNS name)" || bad "KC_HOSTNAME '$host' does not give the issuer $IDP_ISSUER"
case "$IDP_ISSUER" in "http://${IDP_SERVICE}.${IDP_NAMESPACE}.svc.cluster.local:8080/realms/${IDP_REALM}") : ;; *) bad "IDP_ISSUER is not the Service's cluster DNS name" ;; esac

placeholders="$(idp_placeholder_vars | tr '\n' ' ')"
users="$(printf '%s\n' "$IDP_USERS" | awk -F'|' 'NF{print $1"|"$2"|"$3}' | tr '\n' ' ')"
clients="$(printf '%s\n' "$IDP_CLIENTS" | awk -F'|' 'NF{print $1"|"$2}' | tr '\n' ' ')"
if python3 -I - "$IDP_REALM_FILE" "$IDP_REALM" "$placeholders" "$users" "$clients" <<'PY'
import json, re, sys
path, realm_name, ph, users, clients = sys.argv[1:6]
r = json.load(open(path)); errs = []
want_ph = set(ph.split()); seen = set(); in_fields = [0]
PH = re.compile(r"^\$\{(KC_[A-Z_]+)\}$")
def walk(o, at):
    if isinstance(o, dict):
        for k, v in o.items():
            if k.lower() in ("secret", "value", "password", "hashedsaltedvalue", "secretdata", "credentialdata") and isinstance(v, str):
                m = PH.match(v)
                if not m: errs.append(f"{at}.{k} is not a ${{KC_*}} placeholder")
                else: seen.add(m.group(1)); in_fields[0] += 1
            walk(v, f"{at}.{k}")
    elif isinstance(o, list):
        for i, v in enumerate(o): walk(v, f"{at}[{i}]")
walk(r, "realm")
text = open(path).read()
if len(re.findall(r"\$\{[^}]*\}", text)) != in_fields[0]: errs.append("a ${...} placeholder appears outside a secret field")
if seen != want_ph: errs.append(f"placeholders {sorted(seen)} != tables {sorted(want_ph)}")
if r.get("realm") != realm_name: errs.append("realm name")
want_users = {tuple(u.split("|")) for u in users.split()}
got_users = set()
for u in r.get("users", []):
    g = (u.get("groups") or [""])
    if len(g) != 1: errs.append(f"user {u['username']} must be in at most one group")
    m = PH.match(u["credentials"][0]["value"]) if u.get("credentials") else None
    got_users.add((u["username"], g[0].lstrip("/"), m.group(1) if m else ""))
    if u.get("credentials", [{}])[0].get("temporary") is not False: errs.append(f"user {u['username']} password must be temporary=false")
if got_users != want_users: errs.append(f"users {sorted(got_users)} != tables {sorted(want_users)}")
want_groups = {g for _, g, _ in want_users if g}
if {g["name"] for g in r.get("groups", [])} != want_groups: errs.append("groups differ from the user table")
want_clients = {tuple(c.split("|")) for c in clients.split()}
got_clients = set()
for c in r.get("clients", []):
    m = PH.match(c.get("secret", ""))
    got_clients.add((c["clientId"], m.group(1) if m else ""))
    if c.get("publicClient") is not False: errs.append(f"client {c['clientId']} must be confidential")
    if c.get("implicitFlowEnabled"): errs.append(f"client {c['clientId']} enables the implicit flow")
    for u in c.get("redirectUris", []):
        if not re.match(r"^https?://localhost:[0-9]+/", u): errs.append(f"client {c['clientId']} redirect {u} is not on localhost")
    gm = [p for p in c.get("protocolMappers", []) if p.get("config", {}).get("claim.name") == "groups"]
    if not gm or gm[0]["config"].get("full.path") != "false": errs.append(f"client {c['clientId']} lacks the flat groups claim")
if got_clients != want_clients: errs.append(f"clients {sorted(got_clients)} != tables {sorted(want_clients)}")
for e in errs: print("FAIL: realm: " + e, file=sys.stderr)
sys.exit(1 if errs else 0)
PY
then ok "realm '$IDP_REALM': no secret in Git (only \${KC_*} placeholders), users/groups/clients match the tables, localhost redirects, flat groups claim"
else fail=1; fi

[ "$fail" -eq 0 ] || { echo "check-identity: FAILED" >&2; exit 1; }
echo "check-identity: OK"
