#!/bin/sh
# Phase 4b (ADR-0025): mutation cases for lab/argocd/rbac-check.sh
# (check-argocd-rbac). Each case copies the files it reads into a
# throwaway tree, breaks one rule, and expects the check to fail; the real
# files must pass. No cluster, no network. Backs
# `make check-argocd-rbac-regression`.
set -eu
[ -f lab/argocd/rbac-check.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
here="$(pwd)"
root="$(mktemp -d)"; [ -n "${KEEP_CASES:-}" ] || trap 'rm -rf "$root"' EXIT INT TERM; [ -z "${KEEP_CASES:-}" ] || echo "cases in $root"
pass=0; fail=0; n=0

setup() {
  d="$1"; mkdir -p "$d/lab/argocd" "$d/scripts/identity" "$d/platform/identity" "$d/gitops/bootstrap" "$d/.tools/bin"
  cp "$here/lab/argocd/values-lab.yaml" "$here/lab/argocd/rbac-check.sh" "$d/lab/argocd/"
  cp "$here/scripts/identity/_lib.sh" "$d/scripts/identity/"
  cp "$here/platform/identity/realm-platform.json" "$d/platform/identity/"
  cp "$here/gitops/bootstrap/values.yaml" "$d/gitops/bootstrap/"
  ln -s "$here/.tools/bin/yq" "$d/.tools/bin/yq"
}
# $1=description $2=accept|reject $3=mutation (a shell snippet run in the tree)
run_case() {
  n=$((n + 1)); d="$root/case$n"; setup "$d"
  ( cd "$d" && sh -c "$3" ) || { echo "FAIL: setup of '$1' failed" >&2; fail=$((fail + 1)); return; }
  if (cd "$d" && sh lab/argocd/rbac-check.sh > "$d.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$d.out" >&2; fail=$((fail + 1)); fi
}
V=lab/argocd/values-lab.yaml
yqe() { printf '.tools/bin/yq -i %s %s' "'$1'" "$V"; }
csv() { # replace one policy.csv line ($1) with $2 (empty = delete)
  printf "python3 -I -c 'import sys; p=\"%s\"; s=open(p).read(); a=\"      %s\\\\n\"; assert a in s, a; s=s.replace(a, (\"      %s\\\\n\" if \"%s\" else \"\")); open(p,\"w\").write(s)'" "$V" "$1" "$2" "$2"
}

run_case "the real values pass" accept ":"
run_case "the local admin left on is rejected" reject "$(yqe '.configs.cm."admin.enabled" = true')"
run_case "anonymous access is rejected" reject "$(yqe '.configs.cm."users.anonymous.enabled" = "true"')"
run_case "a second local account is rejected" reject "$(yqe '.configs.cm."accounts.ops" = "login"')"
run_case "a literal client secret is rejected" reject "sed -i.bak 's#clientSecret: \$argocd-oidc:clientSecret#clientSecret: hunter2-not-a-ref#' $V"
run_case "another issuer is rejected" reject "sed -i.bak 's#issuer: http://keycloak.keycloak.svc.cluster.local:8080/realms/platform#issuer: https://idp.example.invalid/realms/platform#' $V"
run_case "TLS verification switched off is rejected" reject "sed -i.bak 's#      clientID: argocd#      clientID: argocd\n      insecureSkipVerify: true#' $V"
run_case "a url whose callback the realm refuses is rejected" reject "$(yqe '.configs.cm.url = "https://argocd.example.invalid"')"
run_case "a default role for every signed-in user is rejected" reject "$(yqe '.configs.rbac."policy.default" = "role:readonly"')"
run_case "roles from another claim are rejected" reject "$(yqe '.configs.rbac.scopes = "[email]"')"
run_case "role:admin for a second group is rejected" reject "$(csv 'g, auditors, role:readonly' 'g, auditors, role:admin')"
run_case "a realm group with no role is rejected" reject "$(csv 'g, developers-uat, role:developer-uat' '')"
run_case "a developer reaching another environment is rejected" reject "$(csv 'p, role:developer-dev, applications, sync, platform/platform-*-dev, allow' 'p, role:developer-dev, applications, sync, platform/platform-*-uat, allow')"
run_case "a developer on every application is rejected" reject "$(csv 'p, role:developer-dev, applications, get, platform/platform-*-dev, allow' 'p, role:developer-dev, applications, get, platform/*, allow')"
run_case "a wildcard action is rejected" reject "$(csv 'p, role:developer-uat, applications, sync, platform/platform-*-uat, allow' 'p, role:developer-uat, applications, *, platform/platform-*-uat, allow')"
run_case "a developer allowed to delete is rejected" reject "$(csv 'p, role:developer-dev, logs, get, platform/platform-*-dev, allow' 'p, role:developer-dev, applications, delete, platform/platform-*-dev, allow')"
run_case "a redefined built-in role is rejected" reject "$(csv 'p, role:developer-dev, projects, get, platform, allow' 'p, role:readonly, applications, sync, */*, allow')"
run_case "a developer that cannot sync is rejected" reject "$(csv 'p, role:developer-uat, applications, sync, platform/platform-*-uat, allow' '')"

echo ""
echo "test-rbac-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-rbac-check: FAILED"; exit 1; }
echo "test-rbac-check: OK"
