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
  cp -R "$here/gitops/bootstrap/." "$d/gitops/bootstrap/"
  ln -s "$here/.tools/bin/yq" "$d/.tools/bin/yq"
  ln -s "$here/.tools/bin/helm" "$d/.tools/bin/helm"
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
B=gitops/bootstrap/values.yaml
T=gitops/bootstrap/templates/appproject.yaml
yqe() { printf '.tools/bin/yq -i %s %s' "'$1'" "${2:-$V}"; }
# tpl <old> <new>: replace one exact line fragment of the AppProject template
tpl() { printf "python3 -I -c 'import sys; p=\"%s\"; s=open(p).read(); a=sys.argv[1]; assert s.count(a)==1, a; open(p,\"w\").write(s.replace(a, sys.argv[2]))' %s %s" "$T" "'$1'" "'$2'"; }
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
run_case "a developer policy line in policy.csv is rejected" reject "$(yqe '.configs.rbac."policy.csv" += "p, role:developer-dev, applications, sync, platform-dev/*, allow\n"')"
run_case "a redefined built-in role is rejected" reject "$(yqe '.configs.rbac."policy.csv" += "p, role:readonly, applications, sync, */*, allow\n"')"
run_case "a realm group with no access is rejected" reject "$(yqe 'del(.multicluster.developerGroups.uat)' "$B")"
run_case "a developer group in another environment's project is rejected" reject "$(yqe '.multicluster.developerGroups.dev = "developers-uat"' "$B")"
run_case "a project role with no realm group behind it is rejected" reject "$(yqe '.multicluster.developerGroups.prod = "developers-prod"' "$B")"
run_case "a developer on another project's applications is rejected" reject "$(tpl 'applications, sync, {{ $p }}/*, allow' 'applications, sync, platform-*/*, allow')"
run_case "a wildcard action is rejected" reject "$(tpl 'applications, sync, {{ $p }}/*, allow' 'applications, *, {{ $p }}/*, allow')"
run_case "a developer allowed to delete is rejected" reject "$(tpl 'logs, get, {{ $p }}/*, allow' 'applications, delete, {{ $p }}/*, allow')"
run_case "a developer that cannot sync is rejected" reject "$(tpl '        - p, proj:{{ $p }}:developer, applications, sync, {{ $p }}/*, allow
' '')"
run_case "a deny policy is rejected" reject "$(tpl 'logs, get, {{ $p }}/*, allow' 'logs, get, {{ $p }}/*, deny')"

echo ""
echo "test-rbac-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-rbac-check: FAILED"; exit 1; }
echo "test-rbac-check: OK"
