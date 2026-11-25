#!/bin/sh
# Phase 4b (ADR-0025): the Argo CD local admin as break-glass only. Backs
#   make argocd-breakglass CONFIRM=yes REASON="..." [HOURS=1..8]
#   make argocd-breakglass-off
#   make argocd-breakglass-status
# on any lab cluster running Argo CD (LAB_CLUSTER=).
#
#   on      sets admin.enabled "true" on argocd-cm with who, why, when and
#           the expiry as annotations, and posts ArgoCDBreakGlassActive to
#           the hub's Alertmanager, ending at the expiry. Alertmanager down
#           or absent is a warning, never a reason to refuse: break-glass
#           is for when things are broken.
#   off     sets admin.enabled "false", removes the annotations and
#           resolves the alert. Argo CD refuses the admin's existing
#           tokens at once (measured: 401 within 5 s, no restart).
#   status  read-only; fails while the admin is on past its expiry, or on
#           with no break-glass record.
# The admin password stays in Secret argocd-initial-admin-secret and is
# never printed. The committed values keep admin.enabled false, so the
# next argocd-upgrade also turns it off.
set -eu

[ -f scripts/lab/_lib.sh ] || { echo "FAIL: must be run from the repository root" >&2; exit 1; }
. scripts/lab/_lib.sh
require_repo_root
. scripts/argocd/_lib.sh
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }

P="$ARGOCD_BREAKGLASS_PREFIX"
cm() { pkubectl -n "$ARGOCD_NAMESPACE" get configmap argocd-cm -o json; }
cm >/dev/null 2>&1 || { echo "FAIL: configmap $ARGOCD_NAMESPACE/argocd-cm not found - is Argo CD installed on '$PROJECT_CLUSTER_NAME'?" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

work="$(mktemp -d)"
pf=""
cleanup() { [ -n "$pf" ] && { kill "$pf" 2>/dev/null || true; }; rm -rf "$work"; }
trap cleanup EXIT INT TERM

# alert <startsAt> <endsAt> <summary> <description> <verb> - posts the
# alert to the hub's Alertmanager through a port-forward; prints a warning
# on any failure. Alertmanager refuses endsAt not after startsAt.
alert() {
  if ! pkubectl -n "$ARGOCD_ALERTMANAGER_NAMESPACE" get service "$ARGOCD_ALERTMANAGER_SERVICE" >/dev/null 2>&1; then
    echo "WARNING: no Alertmanager on '$PROJECT_CLUSTER_NAME' ($ARGOCD_ALERTMANAGER_NAMESPACE/$ARGOCD_ALERTMANAGER_SERVICE) - alert $ARGOCD_BREAKGLASS_ALERT not sent"
    return 0
  fi
  port="${ARGOCD_BREAKGLASS_AM_PORT:-19093}"
  KUBECONFIG="$PROJECT_KUBECONFIG" "$KUBECTL_BIN" --kubeconfig "$PROJECT_KUBECONFIG" \
    -n "$ARGOCD_ALERTMANAGER_NAMESPACE" port-forward "service/$ARGOCD_ALERTMANAGER_SERVICE" "$port:9093" >/dev/null 2>&1 &
  pf=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fsS -o /dev/null "http://127.0.0.1:$port/-/ready" 2>/dev/null && break; sleep 1; done
  jq -n --arg a "$ARGOCD_BREAKGLASS_ALERT" --arg c "$PROJECT_CLUSTER_NAME" --arg s "$1" --arg e "$2" \
        --arg sum "$3" --arg d "$4" \
    '[{labels: {alertname: $a, severity: "page", cluster: $c},
       annotations: {summary: $sum, description: $d}, startsAt: $s, endsAt: $e}]' > "$work/alert.json"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data-binary "@$work/alert.json" "http://127.0.0.1:$port/api/v2/alerts" 2>/dev/null || echo 000)"
  kill "$pf" 2>/dev/null || true; pf=""
  if [ "$code" = 200 ]; then echo "OK: Alertmanager: $ARGOCD_BREAKGLASS_ALERT $5"
  else echo "WARNING: Alertmanager answered $code - alert $ARGOCD_BREAKGLASS_ALERT not $5"; fi
}

state() { cm | jq -r --arg p "$P" '[.data["admin.enabled"] // "", .metadata.annotations[$p + "-by"] // "", .metadata.annotations[$p + "-reason"] // "", .metadata.annotations[$p + "-at"] // "", .metadata.annotations[$p + "-expires-at"] // ""] | join("\u001f")'; }

case "${1:-}" in
  on)
    [ "${2:-}" = "--confirm" ] || { echo "FAIL: break-glass turns the Argo CD local admin on - rerun with CONFIRM=yes" >&2; exit 1; }
    reason="${REASON:-}"
    [ -n "$reason" ] || { echo "FAIL: REASON=\"...\" is required (why the admin is needed)" >&2; exit 1; }
    case "$reason" in *"
"*) echo "FAIL: REASON must be one line" >&2; exit 1 ;; esac
    [ "${#reason}" -le 200 ] || { echo "FAIL: REASON is longer than 200 characters" >&2; exit 1; }
    hours="${HOURS:-$ARGOCD_BREAKGLASS_DEFAULT_HOURS}"
    case "$hours" in ''|*[!0-9]*) echo "FAIL: HOURS must be a whole number" >&2; exit 1 ;; esac
    [ "$hours" -ge 1 ] && [ "$hours" -le "$ARGOCD_BREAKGLASS_MAX_HOURS" ] \
      || { echo "FAIL: HOURS must be 1..$ARGOCD_BREAKGLASS_MAX_HOURS" >&2; exit 1; }
    IFS="$(printf '\037')" read -r enabled _by _r _at exp <<S
$(state)
S
    [ "$enabled" = "true" ] && { echo "FAIL: the local admin is already on (until '${exp:-no record}') - make argocd-breakglass-status" >&2; exit 1; }
    who="$(git config user.name 2>/dev/null || true)"; who="${who:-${USER:-unknown}}"
    at="$(now)"
    exp="$(python3 -I -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$hours")"
    jq -n --arg p "$P" --arg by "$who" --arg r "$reason" --arg at "$at" --arg e "$exp" \
      '{data: {"admin.enabled": "true"}, metadata: {annotations: {($p + "-by"): $by, ($p + "-reason"): $r, ($p + "-at"): $at, ($p + "-expires-at"): $e}}}' > "$work/patch.json"
    pkubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cm --type merge --patch-file "$work/patch.json" >/dev/null
    echo "OK: break-glass ON on '$PROJECT_CLUSTER_NAME' - by '$who', until $exp; reason: $reason"
    alert "$at" "$exp" "The Argo CD local admin is on (break-glass) on $PROJECT_CLUSTER_NAME" \
      "Turned on by $who at $at, until $exp. Reason: $reason. Turn it off: make argocd-breakglass-off." "raised until $exp"
    pkubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret >/dev/null 2>&1 \
      && echo "argocd-breakglass: sign in as 'admin'; the password is in Secret $ARGOCD_NAMESPACE/argocd-initial-admin-secret (key password). Never paste it anywhere." \
      || echo "WARNING: Secret $ARGOCD_NAMESPACE/argocd-initial-admin-secret is gone - see docs/runbooks/argocd-access.md"
    echo "argocd-breakglass: every local login pages (ArgoCDLocalAdminLogin). When done: make argocd-breakglass-off"
    ;;
  off)
    IFS="$(printf '\037')" read -r enabled by _r at _exp <<S
$(state)
S
    jq -n --arg p "$P" '{data: {"admin.enabled": "false"}, metadata: {annotations: {($p + "-by"): null, ($p + "-reason"): null, ($p + "-at"): null, ($p + "-expires-at"): null}}}' > "$work/patch.json"
    pkubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cm --type merge --patch-file "$work/patch.json" >/dev/null
    [ "$(cm | jq -r '.data["admin.enabled"]')" = "false" ] || { echo "FAIL: admin.enabled is not false after the patch" >&2; exit 1; }
    echo "OK: break-glass OFF on '$PROJECT_CLUSTER_NAME' - local admin disabled (was '${enabled:-unset}'), its tokens are refused"
    # Same labels as when it was raised, so Alertmanager resolves that
    # alert; started at the recorded time (or a minute ago if unrecorded).
    start="${at:-$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')}"
    alert "$start" "$(now)" "The Argo CD local admin is off again on $PROJECT_CLUSTER_NAME" \
      "Break-glass by ${by:-unknown} at ${at:-unknown} ended at $(now)." "resolved"
    ;;
  status)
    IFS="$(printf '\037')" read -r enabled by reason at exp <<S
$(state)
S
    if [ "$enabled" != "true" ]; then echo "OK: the local admin is off on '$PROJECT_CLUSTER_NAME' (admin.enabled='${enabled}')"; exit 0; fi
    [ -n "$exp" ] || { echo "FAIL: the local admin is ON with no break-glass record - make argocd-breakglass-off" >&2; exit 1; }
    if [ "$(now)" \> "$exp" ]; then
      echo "FAIL: break-glass EXPIRED at $exp (by '$by', reason: $reason) and the admin is still on - make argocd-breakglass-off" >&2; exit 1
    fi
    echo "WARNING: break-glass ON on '$PROJECT_CLUSTER_NAME' - by '$by' at $at, until $exp; reason: $reason"
    ;;
  *) echo "FAIL: usage: breakglass.sh on --confirm | off | status" >&2; exit 1 ;;
esac
