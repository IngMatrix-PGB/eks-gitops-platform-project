#!/bin/sh
# Phase 4b (ADR-0025): offline checks of Argo CD's human access in
# lab/argocd/values-lab.yaml. No cluster, no network. Backs
# `make check-argocd-rbac` (in validate).
#   - the local admin is off and anonymous access is off;
#   - oidc.config: the lab issuer (scripts/identity/_lib.sh), client
#     argocd, the client secret only by reference to the Secret
#     idp-install writes, and the SSO callback on `url` is a redirect the
#     realm's argocd client allows;
#   - rbac: no default role, roles from the `groups` claim, glob matching;
#   - policy.csv: every realm group (except none) mapped to exactly its
#     role; only platform-admins gets role:admin; the built-in roles are
#     not redefined; a developer-<env> role grants only get/sync on
#     applications, get on logs (both on platform/platform-*-<env> of its
#     own environment) and get on the project; no wildcard action, no
#     deny.
set -eu
[ -f scripts/identity/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/identity/_lib.sh
VALUES="lab/argocd/values-lab.yaml"
YQ="${YQ_BIN:-.tools/bin/yq}"
[ -x "$YQ" ] || { echo "FAIL: $YQ missing - run 'make tools-install'" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
"$YQ" -o=json '.configs' "$VALUES" > "$work/configs.json"
"$YQ" -o=json '.configs.cm."oidc.config" // "" | from_yaml' "$VALUES" > "$work/oidc.json" 2>/dev/null || echo '{}' > "$work/oidc.json"
project="$("$YQ" -N '.project.name' gitops/bootstrap/values.yaml)"
groups="$(printf '%s\n' "$IDP_USERS" | awk -F'|' 'NF && $2 != "" {print $2}' | sort -u | tr '\n' ' ')"

python3 -I - "$work/configs.json" "$work/oidc.json" "$IDP_REALM_FILE" "$IDP_ISSUER" "$IDP_ARGOCD_SECRET" "$project" "$groups" <<'PY'
import json, re, sys
configs = json.load(open(sys.argv[1])); oidc = json.load(open(sys.argv[2]) ) or {}
realm = json.load(open(sys.argv[3])); issuer, secret, project = sys.argv[4], sys.argv[5], sys.argv[6]
groups = sys.argv[7].split()
cm, rbac = configs.get("cm") or {}, configs.get("rbac") or {}
fail = 0
def ok(m): print("OK: " + m); return True
def bad(m):
    global fail; fail = 1; print("FAIL: " + m, file=sys.stderr)

# Local admin and anonymous access.
str(cm.get("admin.enabled")).lower() == "false" and ok("the local admin is off (break-glass only)") or bad(f"admin.enabled is {cm.get('admin.enabled')!r}, not false")
str(cm.get("users.anonymous.enabled")).lower() == "false" and ok("anonymous access is off") or bad("users.anonymous.enabled is not false")
extra = sorted(k for k in cm if k.startswith("accounts."))
not extra and ok("no other local account") or bad(f"local accounts defined: {extra}")

# OIDC.
oidc.get("issuer") == issuer and ok(f"OIDC issuer is the lab issuer ({issuer})") or bad(f"OIDC issuer {oidc.get('issuer')!r}, want {issuer!r}")
oidc.get("clientID") == "argocd" and ok("OIDC client argocd") or bad(f"OIDC clientID {oidc.get('clientID')!r}, want 'argocd'")
want_ref = f"${secret}:clientSecret"
oidc.get("clientSecret") == want_ref and ok(f"client secret only by reference ({want_ref})") or bad(f"clientSecret is not exactly {want_ref!r} (a literal secret, or another Secret)")
for k in ("insecureSkipVerify", "rootCA", "cliClientID"):
    if k in oidc: bad(f"oidc.config sets {k}, not part of the lab design")
url = cm.get("url", "")
client = next((c for c in realm.get("clients", []) if c.get("clientId") == "argocd"), {})
cb = url.rstrip("/") + "/auth/callback"
url.startswith("https://localhost:") and cb in client.get("redirectUris", []) \
    and ok(f"SSO callback {cb} is a redirect the realm's argocd client allows") \
    or bad(f"url {url!r}: callback {cb!r} not in the realm's argocd redirectUris {client.get('redirectUris')}")

# RBAC settings.
rbac.get("policy.default", None) == "" and ok("no default role (policy.default empty)") or bad(f"policy.default is {rbac.get('policy.default')!r}, want ''")
rbac.get("scopes") == "[groups]" and ok("roles from the groups claim") or bad(f"scopes is {rbac.get('scopes')!r}, want '[groups]'")
rbac.get("policy.matchMode", "glob") == "glob" or bad("policy.matchMode is not glob")
if rbac.get("policy.default") == "role:readonly" or rbac.get("policy.default") == "role:admin":
    bad("a default role gives every signed-in user access")

# policy.csv.
g, p = {}, []
for n, line in enumerate((rbac.get("policy.csv") or "").splitlines(), 1):
    line = line.strip()
    if not line or line.startswith("#"): continue
    f = [x.strip() for x in line.split(",")]
    if f[0] == "g" and len(f) == 3:
        if f[1] in g: bad(f"policy.csv:{n}: group {f[1]} mapped twice")
        g[f[1]] = f[2]
    elif f[0] == "p" and len(f) == 6: p.append((n, f[1:]))
    else: bad(f"policy.csv:{n}: not a 'g, group, role' or 'p, sub, res, act, obj, eff' line")
want = {}
for grp in groups:
    if grp == "platform-admins": want[grp] = "role:admin"
    elif grp == "auditors": want[grp] = "role:readonly"
    elif grp.startswith("developers-"): want[grp] = "role:developer-" + grp[len("developers-"):]
    else: bad(f"realm group {grp} has no role in this design")
g == want and ok(f"every realm group mapped to its role ({len(g)})") or bad(f"group mappings {g}, want {want}")
[k for k, v in g.items() if v == "role:admin"] == ["platform-admins"] or bad("role:admin granted to a group other than platform-admins")
allowed = {("applications", "get"), ("applications", "sync"), ("logs", "get"), ("projects", "get")}
seen = {}
for n, (sub, res, act, obj, eff) in p:
    m = re.fullmatch(r"role:developer-([a-z]+)", sub)
    if not m: bad(f"policy.csv:{n}: grant to {sub} - only role:developer-<env> roles are defined here (built-ins are not redefined)"); continue
    env = m.group(1)
    if eff != "allow": bad(f"policy.csv:{n}: effect {eff!r} - use no deny, grant only what is needed")
    if (res, act) not in allowed: bad(f"policy.csv:{n}: {sub} gets {res}/{act} - developers get only {sorted(allowed)}")
    want_obj = project if res == "projects" else f"{project}/platform-*-{env}"
    if obj != want_obj: bad(f"policy.csv:{n}: {sub} on {obj!r} - want {want_obj!r} (its own environment only)")
    seen.setdefault(sub, set()).add((res, act))
for grp, role in want.items():
    if role.startswith("role:developer-") and not {("applications", "get"), ("applications", "sync")} <= seen.get(role, set()):
        bad(f"{role} cannot get and sync its own applications")
not fail and ok(f"{len(p)} developer grants, each limited to its own environment in project {project}")
sys.exit(fail)
PY
echo "check-argocd-rbac: OK"
