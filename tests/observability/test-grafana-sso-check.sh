#!/bin/sh
# Phase 4c (ADR-0025): mutation cases for lab/observability/sso-check.sh
# (check-grafana-sso). Each case copies the files it reads into a
# throwaway tree, breaks one rule, and expects the check to fail; the real
# files must pass. No cluster, no network. Backs
# `make check-grafana-sso-regression`.
set -eu
[ -f lab/observability/sso-check.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
here="$(pwd)"
root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0; n=0

setup() {
  d="$1"; mkdir -p "$d/lab/observability" "$d/scripts/observability" "$d/scripts/identity" "$d/scripts/lib" "$d/platform/identity" "$d/.tools/bin"
  cp "$here/lab/observability/sso-check.sh" "$d/lab/observability/"
  cp "$here/scripts/observability/_lib.sh" "$d/scripts/observability/"
  cp "$here/scripts/identity/_lib.sh" "$d/scripts/identity/"
  cp "$here/scripts/lib/helm.sh" "$d/scripts/lib/"
  cp "$here/platform/identity/realm-platform.json" "$d/platform/identity/"
  ln -s "$here/.tools/bin/yq" "$d/.tools/bin/yq"
}
# $1=description $2=accept|reject $3=mutation (a shell snippet run in the tree)
run_case() {
  n=$((n + 1)); d="$root/case$n"; setup "$d"
  ( cd "$d" && sh -c "$3" ) || { echo "FAIL: setup of '$1' failed" >&2; fail=$((fail + 1)); return; }
  if (cd "$d" && sh lab/observability/sso-check.sh > "$d.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$d.out" >&2; fail=$((fail + 1)); fi
}
L=scripts/observability/_lib.sh
sub() { printf "python3 -I -c 'import sys; p=\"%s\"; s=open(p).read(); a=sys.argv[1]; assert a in s, a; open(p,\"w\").write(s.replace(a, sys.argv[2], 1))' %s %s" "$1" "'$2'" "'$3'"; }

run_case "the real values pass" accept ":"
run_case "anonymous access is rejected" reject "$(sub $L '  auth.anonymous:
    enabled: false' '  auth.anonymous:
    enabled: true')"
run_case "a client secret in the values is rejected" reject "$(sub $L '    client_id: grafana' '    client_id: grafana
    client_secret: hunter2-in-git')"
run_case "PKCE off is rejected" reject "$(sub $L '    use_pkce: true' '    use_pkce: false')"
run_case "a token URL off the lab issuer is rejected" reject "$(sub $L 'token_url: ${IDP_ISSUER}' 'token_url: https://idp.example.invalid/realms/platform')"
run_case "a client the realm does not define is rejected" reject "$(sub $L '    client_id: grafana' '    client_id: grafana-other')"
# The role expression holds single quotes: those two mutations are files.
cat > "$root/viewer-default.py" <<'M'
p = "scripts/observability/_lib.sh"; s = open(p).read()
a = "&& 'Viewer' || ''\""; assert a in s
open(p, "w").write(s.replace(a, "&& 'Viewer' || 'Viewer'\"", 1))
M
cat > "$root/admin-auditors.py" <<'M'
p = "scripts/observability/_lib.sh"; s = open(p).read()
a = "contains(groups[*], 'platform-admins') && 'Admin'"; assert a in s
open(p, "w").write(s.replace(a, "(contains(groups[*], 'platform-admins') || contains(groups[*], 'auditors')) && 'Admin'", 1))
M
run_case "a Viewer default for unmapped users is rejected" reject "python3 -I $root/viewer-default.py"
run_case "Admin for auditors is rejected" reject "python3 -I $root/admin-auditors.py"
run_case "a lenient role check is rejected" reject "$(sub $L '    role_attribute_strict: true' '    role_attribute_strict: false')"
run_case "SSO granting Grafana server admin is rejected" reject "$(sub $L '    allow_assign_grafana_admin: false' '    allow_assign_grafana_admin: true')"
run_case "skipping role sync is rejected" reject "$(sub $L '    skip_org_role_sync: false' '    skip_org_role_sync: true')"
run_case "a root_url whose callback the realm refuses is rejected" reject "$(sub $L 'OBS_GRAFANA_ROOT_URL="http://localhost:3000"' 'OBS_GRAFANA_ROOT_URL="http://localhost:3001"')"
run_case "Grafana reading another Secret than idp-install writes is rejected" reject "$(sub $L 'OBS_SECRET_GRAFANA_OIDC="obs-grafana-oidc"' 'OBS_SECRET_GRAFANA_OIDC="grafana-sso"')"
run_case "a required (non-optional) client Secret is rejected" reject "$(sub $L '    optional: true' '    optional: false')"

echo ""
echo "test-grafana-sso-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-grafana-sso-check: FAILED"; exit 1; }
echo "test-grafana-sso-check: OK"
