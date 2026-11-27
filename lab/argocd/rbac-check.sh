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
#   - policy.csv: only group mappings - platform-admins to role:admin,
#     auditors to role:readonly - and no policy line (no developer role,
#     no redefined built-in);
#   - developers (ADR-0026): each realm group developers-<env> is the only
#     group of the role `developer` of AppProject <project>-<env> in the
#     lab hub's render of gitops/bootstrap, with exactly get/sync on
#     applications and get on logs of <project>-<env>/*; no other project
#     has a role, and no realm group is left without access.
set -eu
[ -f scripts/identity/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
. scripts/identity/_lib.sh
VALUES="lab/argocd/values-lab.yaml"
YQ="${YQ_BIN:-.tools/bin/yq}"
HELM="${HELM_BIN:-.tools/bin/helm}"
[ -x "$YQ" ] || { echo "FAIL: $YQ missing - run 'make tools-install'" >&2; exit 1; }
[ -x "$HELM" ] || { echo "FAIL: $HELM missing - run 'make tools-install'" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT INT TERM
"$YQ" -o=json '.configs' "$VALUES" > "$work/configs.json"
"$YQ" -o=json '.configs.cm."oidc.config" // "" | from_yaml' "$VALUES" > "$work/oidc.json" 2>/dev/null || echo '{}' > "$work/oidc.json"
project="$("$YQ" -N '.project.name' gitops/bootstrap/values.yaml)"
"$HELM" template gitops/bootstrap --set profile=local-multicluster > "$work/bootstrap.yaml" || { echo "FAIL: gitops/bootstrap does not render for the lab hub" >&2; exit 1; }
"$YQ" -o=json ea '[select(.kind == "AppProject")]' "$work/bootstrap.yaml" > "$work/projects.json"
groups="$(printf '%s\n' "$IDP_USERS" | awk -F'|' 'NF && $2 != "" {print $2}' | sort -u | tr '\n' ' ')"

python3 -I - "$work/configs.json" "$work/oidc.json" "$IDP_REALM_FILE" "$IDP_ISSUER" "$IDP_ARGOCD_SECRET" "$project" "$groups" "$work/projects.json" <<'PY'
import json, re, sys
configs = json.load(open(sys.argv[1])); oidc = json.load(open(sys.argv[2]) ) or {}
realm = json.load(open(sys.argv[3])); issuer, secret, project = sys.argv[4], sys.argv[5], sys.argv[6]
groups = sys.argv[7].split()
projects = {p["metadata"]["name"]: p.get("spec") or {} for p in json.load(open(sys.argv[8]))}
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
for n, _ in p: bad(f"policy.csv:{n}: a policy line - developers get access only through their AppProject's role (ADR-0026), and built-ins are not redefined")
want = {"platform-admins": "role:admin", "auditors": "role:readonly"}
for grp in groups:
    if grp not in want and not grp.startswith("developers-"): bad(f"realm group {grp} has no role in this design")
g == {k: v for k, v in want.items() if k in groups} and ok(f"policy.csv maps exactly platform-admins to role:admin and auditors to role:readonly ({len(g)})") \
    or bad(f"policy.csv group mappings {g}, want {want} only")

# Developers: AppProject roles (ADR-0026).
allowed = {"applications get", "applications sync", "logs get"}
dev_groups = sorted(x for x in groups if x.startswith("developers-"))
for grp in dev_groups:
    env = grp[len("developers-"):]
    name = f"{project}-{env}"
    roles = projects.get(name, {}).get("roles") or []
    if name not in projects: bad(f"{grp}: AppProject {name} is not rendered"); continue
    if [r.get("name") for r in roles] != ["developer"]: bad(f"{name}: roles {[r.get('name') for r in roles]}, want exactly ['developer']"); continue
    r = roles[0]
    r.get("groups") == [grp] or bad(f"{name}: role developer groups {r.get('groups')}, want exactly [{grp!r}]")
    got = set()
    for line in r.get("policies") or []:
        f = [x.strip() for x in line.split(",")]
        if len(f) != 6 or f[0] != "p": bad(f"{name}: policy {line!r} is not 'p, sub, res, act, obj, eff'"); continue
        _, sub, res, act, obj, eff = f
        sub == f"proj:{name}:developer" or bad(f"{name}: policy subject {sub!r}, want 'proj:{name}:developer'")
        eff == "allow" or bad(f"{name}: effect {eff!r} - use no deny, grant only what is needed")
        f"{res} {act}" in allowed or bad(f"{name}: developers get {res}/{act} - only {sorted(allowed)}")
        obj == f"{name}/*" or bad(f"{name}: policy on {obj!r} - want {name + '/*'!r} (its own project only)")
        got.add(f"{res} {act}")
    {"applications get", "applications sync"} <= got or bad(f"{name}: developers cannot get and sync its applications")
for name, spec in projects.items():
    rs = spec.get("roles") or []
    if not rs: continue
    env = name[len(project) + 1:] if name.startswith(project + "-") else None
    if f"developers-{env}" not in dev_groups: bad(f"AppProject {name} has roles {[x.get('name') for x in rs]} but no realm group developers-{env}")
not fail and ok(f"{len(dev_groups)} developer groups, each only in the role of its own AppProject ({', '.join(project + '-' + x[len('developers-'):] for x in dev_groups)})")
sys.exit(fail)
PY
echo "check-argocd-rbac: OK"
