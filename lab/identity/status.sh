#!/bin/sh
# Phase 4a (ADR-0025): read-only live check of the lab identity provider
# on the hub. Backs `make idp-status`.
#   1. the Deployment is Ready, on the pinned image;
#   2. inside the cluster (a pinned curl pod), the discovery document
#      carries exactly IDP_ISSUER - what Argo CD and Grafana will see;
#   3. through a port-forward, each test user gets a token whose issuer is
#      the same IDP_ISSUER and whose groups claim is exactly its group
#      (none for nogroup-user); a wrong password is refused;
#   4. the pod's memory, measured.
# Passwords come from .local/identity/ and client secrets from the
# cluster; none is printed or put on argv (curl reads them from files).
set -eu
[ -f scripts/lab/_lib.sh ] || { echo "FAIL: must be run from the repository root" >&2; exit 1; }
[ "${LAB_CLUSTER:-}" = hub ] || { echo "FAIL: LAB_CLUSTER=hub" >&2; exit 1; }
. scripts/lab/_lib.sh
. scripts/identity/_lib.sh
. scripts/workload/_lib.sh
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
work="$(mktemp -d)"; pf=""
cleanup() { if [ -n "$pf" ]; then kill "$pf" 2>/dev/null || true; fi; pkubectl -n "$IDP_NAMESPACE" delete pod idp-status-probe --ignore-not-found --wait=false >/dev/null 2>&1; rm -rf "$work"; return 0; }
trap cleanup EXIT INT TERM
umask 077

# 1
ready="$(pkubectl -n "$IDP_NAMESPACE" get deployment "$IDP_DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
img="$(pkubectl -n "$IDP_NAMESPACE" get deployment "$IDP_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ "$ready" = 1 ] && ok "Keycloak Ready (1/1)" || bad "Keycloak not Ready (readyReplicas='${ready}') - make idp-install"
[ "$img" = "$IDP_IMAGE" ] && ok "running the pinned image" || bad "running '$img', not IDP_IMAGE"
[ "$fail" -eq 0 ] || exit 1

# 2 - in-cluster discovery, from a pinned, restricted curl pod.
pkubectl -n "$IDP_NAMESPACE" delete pod idp-status-probe --ignore-not-found --wait=true >/dev/null 2>&1 || true
pkubectl -n "$IDP_NAMESPACE" run idp-status-probe --image="$TEST_CLIENT_IMAGE" --restart=Never --quiet \
  --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"idp-status-probe","image":"'"$TEST_CLIENT_IMAGE"'","args":["-fsS","--max-time","10","'"$IDP_ISSUER"'/.well-known/openid-configuration"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
pkubectl -n "$IDP_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/idp-status-probe --timeout=90s >/dev/null 2>&1 || true
disc_iss="$(pkubectl -n "$IDP_NAMESPACE" logs idp-status-probe 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["issuer"])' 2>/dev/null || true)"
[ "$disc_iss" = "$IDP_ISSUER" ] && ok "in-cluster discovery: issuer $disc_iss" || bad "in-cluster discovery issuer '$disc_iss' (want $IDP_ISSUER)"

# 3 - tokens through a port-forward.
port="${IDP_LOCAL_PORT:-18080}"
# The binary itself in the background (not the pkubectl function), so $!
# is kubectl's own PID and the cleanup stops exactly it.
KUBECONFIG="$PROJECT_KUBECONFIG" "$KUBECTL_BIN" --kubeconfig "$PROJECT_KUBECONFIG" \
  -n "$IDP_NAMESPACE" port-forward "service/$IDP_SERVICE" "$port:8080" >/dev/null 2>&1 &
pf=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fsS -o /dev/null "http://127.0.0.1:$port/realms/$IDP_REALM" 2>/dev/null && break; sleep 1; done
idp_secret_key pkubectl "$IDP_SECRET_REALM" KC_CLIENT_SECRET_ARGOCD > "$work/client-secret" || bad "no argocd client secret in the cluster"
token_url="http://127.0.0.1:$port/realms/$IDP_REALM/protocol/openid-connect/token"
# token <user> <password-file> - writes the response body to $work/resp, prints the HTTP code.
token() {
  curl -sS -o "$work/resp" -w '%{http_code}' -X POST "$token_url" \
    --data-urlencode grant_type=password --data-urlencode client_id=argocd \
    --data-urlencode "client_secret@$work/client-secret" \
    --data-urlencode "username=$1" --data-urlencode "password@$2" --data-urlencode scope=openid
}
printf '%s\n' "$IDP_USERS" | while IFS='|' read -r u g _v; do
  [ -n "$u" ] || continue
  [ -f "$IDP_LOCAL_DIR/$u" ] || { echo "FAIL: $IDP_LOCAL_DIR/$u missing - make idp-install" >&2; echo 1 > "$work/failed"; continue; }
  code="$(token "$u" "$IDP_LOCAL_DIR/$u")"
  if [ "$code" != 200 ]; then echo "FAIL: $u: token endpoint answered $code" >&2; echo 1 > "$work/failed"; continue; fi
  got="$(python3 -I - "$work/resp" <<'PY'
import base64, json, sys
t = json.load(open(sys.argv[1]))["id_token"].split(".")[1]
c = json.loads(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4)))
print(c["iss"] + " " + ",".join(sorted(c.get("groups", []))) + " " + c.get("aud", "") if isinstance(c.get("aud"), str) else c["iss"] + " " + ",".join(sorted(c.get("groups", []))) + " " + ",".join(c.get("aud", [])))
PY
)"
  iss="${got%% *}"; rest="${got#* }"; groups="${rest%% *}"; aud="${rest#* }"
  if [ "$iss" = "$IDP_ISSUER" ] && [ "$groups" = "$g" ] && [ "$aud" = argocd ]; then
    echo "OK: $u: token issuer $iss, groups [${groups}], audience argocd"
  else
    echo "FAIL: $u: issuer '$iss', groups '[${groups}]' (want [$g]), audience '$aud'" >&2; echo 1 > "$work/failed"
  fi
done
[ -f "$work/failed" ] && fail=1
printf 'not-the-password' > "$work/wrong"
code="$(token dev-user "$work/wrong")"
err="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error",""))' "$work/resp" 2>/dev/null || true)"
case "$code:$err" in
  400:invalid_grant|401:invalid_grant) ok "a wrong password is refused ($code invalid_grant)" ;;
  *) bad "a wrong password answered $code '$err' (want invalid_grant)" ;;
esac

# 4
# The container's own cgroup counter (the hub runs no metrics-server).
mem="$(pkubectl -n "$IDP_NAMESPACE" exec deploy/"$IDP_DEPLOYMENT" -- cat /sys/fs/cgroup/memory.current 2>/dev/null | awk '{printf "%d MiB", $1 / 1048576}')"
echo "INFO: Keycloak memory: ${mem:-unknown}"

[ "$fail" -eq 0 ] || { echo "idp-status: FAILED" >&2; exit 1; }
echo "idp-status: OK"
exit 0
