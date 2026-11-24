#!/bin/sh
# Phase 4a (ADR-0025): mutation cases for lab/identity/render.sh (check-
# identity). Each case copies the identity files into a throwaway tree,
# breaks one rule, and expects the check to fail; the real files must
# pass. No cluster, no network. Backs `make check-identity-regression`.
set -eu
[ -f lab/identity/render.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
here="$(pwd)"
root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0; n=0

setup() {
  d="$1"; mkdir -p "$d/platform/identity" "$d/scripts/identity" "$d/lab/identity" "$d/.tools/bin"
  cp "$here/platform/identity/keycloak.yaml" "$here/platform/identity/realm-platform.json" "$d/platform/identity/"
  cp "$here/scripts/identity/_lib.sh" "$d/scripts/identity/"
  cp "$here/lab/identity/render.sh" "$d/lab/identity/"
  ln -s "$here/.tools/bin/yq" "$d/.tools/bin/yq"
}
# $1=description $2=accept|reject $3=mutation (a shell snippet run in the tree)
run_case() {
  n=$((n + 1)); d="$root/case$n"; setup "$d"
  ( cd "$d" && sh -c "$3" ) || { echo "FAIL: setup of '$1' failed" >&2; fail=$((fail + 1)); return; }
  if (cd "$d" && sh lab/identity/render.sh > "$d.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$d.out" >&2; fail=$((fail + 1)); fi
}
jq_edit() { # python edit of the realm: $1 = statement on r
  printf 'python3 -I -c '"'"'import json; p="platform/identity/realm-platform.json"; r=json.load(open(p)); %s; open(p,"w").write(json.dumps(r))'"'" "$1"
}

run_case "the real identity files pass" accept ":"
run_case "a client secret written in the realm is rejected" reject "$(jq_edit 'r["clients"][0]["secret"]="s3cr3t-value"')"
run_case "a user password written in the realm is rejected" reject "$(jq_edit 'r["users"][1]["credentials"][0]["value"]="hunter2"')"
run_case "a placeholder outside a secret field is rejected" reject "$(jq_edit 'r["displayName"]="${KC_PW_ADMIN_USER}"')"
run_case "a user missing from the tables is rejected" reject "$(jq_edit 'r["users"].append(dict(r["users"][0], username="extra-user"))')"
run_case "a user in another group than the table says is rejected" reject "$(jq_edit 'r["users"][1]["groups"]=["platform-admins"]')"
run_case "a public client is rejected" reject "$(jq_edit 'r["clients"][0]["publicClient"]=True')"
run_case "the implicit flow is rejected" reject "$(jq_edit 'r["clients"][1]["implicitFlowEnabled"]=True')"
run_case "a redirect URI off localhost is rejected" reject "$(jq_edit 'r["clients"][0]["redirectUris"]=["https://argocd.example.invalid/auth/callback"]')"
run_case "a temporary password is rejected" reject "$(jq_edit 'r["users"][0]["credentials"][0]["temporary"]=True')"
run_case "groups with full paths are rejected" reject "$(jq_edit 'r["clients"][0]["protocolMappers"][0]["config"]["full.path"]="true"')"
run_case "an image without a digest is rejected" reject "sed -i.bak 's#@sha256:[0-9a-f]*\"#\"#' scripts/identity/_lib.sh"
run_case "privilege escalation is rejected" reject "sed -i.bak 's#allowPrivilegeEscalation: false#allowPrivilegeEscalation: true#' platform/identity/keycloak.yaml"
run_case "a namespace not enforcing restricted is rejected" reject "sed -i.bak 's#pod-security.kubernetes.io/enforce: restricted#pod-security.kubernetes.io/enforce: baseline#' platform/identity/keycloak.yaml"
run_case "a mounted ServiceAccount token is rejected" reject "sed -i.bak 's#^      automountServiceAccountToken: false#      automountServiceAccountToken: true#' platform/identity/keycloak.yaml"
run_case "an issuer off the in-cluster Service name is rejected" reject "sed -i.bak 's#^IDP_ISSUER=.*#IDP_ISSUER=\"http://localhost:8080/realms/platform\"#' scripts/identity/_lib.sh"

echo ""
echo "test-identity-render: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-identity-render: FAILED"; exit 1; }
echo "test-identity-render: OK"
