#!/bin/sh
# Phase 4b (ADR-0025): the live role matrix on the lab-multicluster hub.
# Backs `make argocd-test-sso` (LAB_CLUSTER=hub). Read-only: syncs are
# dry runs, nothing in the cluster changes.
#   1. the client Secret argocd-oidc exists and the local admin is off;
#   2. a Keycloak id_token per test user against the Argo CD API:
#      - platform-admins: every Application, dry-run sync of any;
#      - developers-<env>: lists and gets only platform-*-<env>, dry-run
#        syncs them; 403 on the other environment and the root;
#      - auditors: every Application, 403 on sync;
#      - no group: lists nothing, 403 on get;
#   3. a forged token gets 401, and the local admin's login 401.
set -eu
[ -f scripts/lab/_lib.sh ] || { echo "FAIL: must be run from the repository root" >&2; exit 1; }
[ "${LAB_CLUSTER:-}" = hub ] || { echo "FAIL: the role matrix runs on the hub (Keycloak and Argo CD) - LAB_CLUSTER=hub" >&2; exit 1; }
. scripts/lab/_lib.sh
require_repo_root
. scripts/argocd/_lib.sh
. scripts/identity/_lib.sh
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }
work="$(mktemp -d)"
. tests/argocd/_sso.sh
trap sso_cleanup EXIT INT TERM

fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# 1
pkubectl -n "$ARGOCD_NAMESPACE" get secret "$IDP_ARGOCD_SECRET" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null \
  | grep -qx argocd && ok "Secret $ARGOCD_NAMESPACE/$IDP_ARGOCD_SECRET present, labeled part-of=argocd" \
  || bad "Secret $ARGOCD_NAMESPACE/$IDP_ARGOCD_SECRET missing or unlabeled - make idp-install"
admin="$(pkubectl -n "$ARGOCD_NAMESPACE" get configmap argocd-cm -o jsonpath='{.data.admin\.enabled}')"
[ "$admin" = false ] && ok "argocd-cm: admin.enabled=false" || bad "argocd-cm: admin.enabled='$admin' - make argocd-breakglass-status"

sso_up
all="$(pkubectl -n "$ARGOCD_NAMESPACE" get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | tr '\n' ' ')"
only() { printf '%s\n' $all | grep -E -e "$1" | tr '\n' ' '; }

# 2
B='{"dryRun":true,"prune":false}'
# idle <app> - waits (up to 60 s) until the Application runs no operation:
# a dry-run sync is an operation too, and a second one while the first
# runs is refused with "another operation is already in progress".
idle() {
  for _ in $(seq 1 30); do
    ph="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "$1" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [ "$ph" != Running ] && [ "$ph" != Terminating ] && return 0
    sleep 2
  done
}
# expect <user> <METHOD> <app|-> <code> - one API call, compared.
expect() {
  if [ "$3" = - ]; then path="/api/v1/applications"; else path="/api/v1/applications/$3"; fi
  if [ "$2" = SYNC ]; then idle "$3"; code="$(sso_api "$work/tok.$1" POST "$path/sync" "$B")"
  else code="$(sso_api "$work/tok.$1" GET "$path")"; fi
  [ "$code" = "$4" ] && ok "$1: $2 ${3} -> $code" || bad "$1: $2 ${3} -> $code (want $4; $(head -c 160 "$work/body"))"
}
# lists <user> <expected space-separated names>
lists() {
  code="$(sso_api "$work/tok.$1" GET /api/v1/applications)"
  got="$(jq -r '.items // [] | .[].metadata.name' "$work/body" | sort | tr '\n' ' ')"
  [ "$code" = 200 ] && [ "$got" = "$2" ] && ok "$1 sees [${got% }]" || bad "$1 sees [${got% }] ($code), want [${2% }]"
}
for u in admin-user dev-user uat-user auditor-user nogroup-user; do sso_token "$u"; done

lists admin-user "$all"
expect admin-user SYNC platform-bootstrap 200
expect admin-user SYNC platform-smoke-uat 200

lists dev-user "$(only '-dev$')"
expect dev-user GET platform-smoke-dev 200
expect dev-user SYNC platform-smoke-dev 200
expect dev-user GET platform-smoke-uat 403
expect dev-user SYNC platform-smoke-uat 403
expect dev-user GET platform-bootstrap 403

lists uat-user "$(only '-uat$')"
expect uat-user SYNC platform-smoke-uat 200
expect uat-user GET platform-smoke-dev 403
expect uat-user SYNC platform-smoke-dev 403

lists auditor-user "$all"
expect auditor-user GET platform-smoke-dev 200
expect auditor-user SYNC platform-smoke-dev 403
expect auditor-user SYNC platform-bootstrap 403

lists nogroup-user ""
expect nogroup-user GET platform-smoke-dev 403
expect nogroup-user SYNC platform-smoke-dev 403

# 3
printf 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.' > "$work/tok.forged"
code="$(sso_api "$work/tok.forged" GET /api/v1/applications)"
[ "$code" = 401 ] && ok "a forged token -> 401" || bad "a forged token -> $code (want 401)"
code="$(sso_admin_login)"
[ "$code" = 401 ] && ok "local admin login -> 401 (break-glass off)" || bad "local admin login -> $code (want 401 while break-glass is off)"

[ "$fail" -eq 0 ] || { echo "argocd-test-sso: FAILED" >&2; exit 1; }
echo "argocd-test-sso: OK"
exit 0
