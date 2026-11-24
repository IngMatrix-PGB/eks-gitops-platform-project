#!/bin/sh
# Phase 4b (ADR-0025): the break-glass cycle, live on the lab-multicluster
# hub. Backs `make argocd-test-breakglass` (LAB_CLUSTER=hub). It turns the
# local admin on for this test only and always turns it off again, also
# on failure or interrupt.
#   1. off: admin login 401;
#   2. on (REASON, HOURS=1): login 200, its token lists Applications,
#      ArgoCDBreakGlassActive active in Alertmanager, status passes;
#      an expiry in the past makes status fail;
#   3. the login reaches Prometheus: ArgoCDLocalAdminLogin active;
#   4. off: the token from step 2 gets 401, a new login 401,
#      ArgoCDBreakGlassActive no longer active, status passes.
set -eu
[ -f scripts/lab/_lib.sh ] || { echo "FAIL: must be run from the repository root" >&2; exit 1; }
[ "${LAB_CLUSTER:-}" = hub ] || { echo "FAIL: the break-glass test runs on the hub (Alertmanager, Prometheus) - LAB_CLUSTER=hub" >&2; exit 1; }
. scripts/lab/_lib.sh
require_repo_root
. scripts/argocd/_lib.sh
. scripts/identity/_lib.sh
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }
work="$(mktemp -d)"
. tests/argocd/_sso.sh
AM_PORT="${AM_PORT:-19094}"
turned_on=0
cleanup() {
  [ "$turned_on" = 1 ] && { sh lab/argocd/breakglass.sh off >/dev/null 2>&1 || echo "FAIL: could not turn break-glass off - run make argocd-breakglass-off" >&2; }
  sso_cleanup
}
trap cleanup EXIT INT TERM

fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
# active <alertname> - 0 when Alertmanager has it active.
active() {
  curl -sS -G "http://127.0.0.1:$AM_PORT/api/v2/alerts" --data-urlencode active=true --data-urlencode silenced=false \
    --data-urlencode inhibited=false --data-urlencode "filter=alertname=\"$1\"" 2>/dev/null \
    | jq -e 'length > 0' >/dev/null
}
# wait_for <seconds> <command...> - polls every 5 s.
wait_for() {
  wf_t="$1"; shift; wf_i=0
  while [ "$wf_i" -lt "$wf_t" ]; do "$@" && return 0; sleep 5; wf_i=$((wf_i + 5)); done
  return 1
}

sh lab/argocd/breakglass.sh status >/dev/null || { echo "FAIL: break-glass is not off before the test - make argocd-breakglass-status" >&2; exit 1; }
sso_up
sso_forward "$ARGOCD_ALERTMANAGER_NAMESPACE" "$ARGOCD_ALERTMANAGER_SERVICE" "$AM_PORT:9093" "http://127.0.0.1:$AM_PORT/-/ready"

# 1
code="$(sso_admin_login)"
[ "$code" = 401 ] && ok "off: admin login -> 401" || bad "off: admin login -> $code (want 401)"

# 2
turned_on=1
REASON="argocd-test-breakglass: live test" HOURS=1 sh lab/argocd/breakglass.sh on --confirm
login_ok() { [ "$(sso_admin_login)" = 200 ]; }
wait_for 30 login_ok && ok "on: admin login -> 200" || bad "on: admin login never succeeded"
cp "$work/tok.admin" "$work/tok.kept"
code="$(sso_api "$work/tok.kept" GET /api/v1/applications)"
[ "$code" = 200 ] && ok "on: the admin token lists Applications" || bad "on: the admin token -> $code"
active "$ARGOCD_BREAKGLASS_ALERT" && ok "on: $ARGOCD_BREAKGLASS_ALERT active in Alertmanager" || bad "on: $ARGOCD_BREAKGLASS_ALERT not active"
sh lab/argocd/breakglass.sh status >/dev/null 2>&1 && ok "on: status passes inside the window" || bad "on: status fails inside the window"
pkubectl -n "$ARGOCD_NAMESPACE" annotate configmap argocd-cm --overwrite "${ARGOCD_BREAKGLASS_PREFIX}-expires-at=2000-01-01T00:00:00Z" >/dev/null
if sh lab/argocd/breakglass.sh status >/dev/null 2>&1; then bad "on: status passes with an expiry in the past"; else ok "on: status fails once expired"; fi

# 3
login_alert() { active ArgoCDLocalAdminLogin; }
wait_for 180 login_alert && ok "the login raised ArgoCDLocalAdminLogin (Prometheus -> Alertmanager)" || bad "ArgoCDLocalAdminLogin not active within 3 minutes"

# 4
sh lab/argocd/breakglass.sh off
turned_on=0
token_refused() { [ "$(sso_api "$work/tok.kept" GET /api/v1/applications)" = 401 ]; }
wait_for 30 token_refused && ok "off: the earlier admin token -> 401" || bad "off: the earlier admin token still works"
code="$(sso_admin_login)"
[ "$code" = 401 ] && ok "off: admin login -> 401" || bad "off: admin login -> $code (want 401)"
if active "$ARGOCD_BREAKGLASS_ALERT"; then bad "off: $ARGOCD_BREAKGLASS_ALERT still active"; else ok "off: $ARGOCD_BREAKGLASS_ALERT resolved"; fi
sh lab/argocd/breakglass.sh status >/dev/null 2>&1 && ok "off: status passes" || bad "off: status fails"
rm -f "$work/tok.kept" "$work/tok.admin"

[ "$fail" -eq 0 ] || { echo "argocd-test-breakglass: FAILED" >&2; exit 1; }
echo "argocd-test-breakglass: OK"
exit 0
