#!/bin/sh
# Phase 6.4a (ADR-0024): the evidence of the sandbox session, read-only.
# Proves what DoD criterion 4 asks for, on the real clusters:
#   1. the hub's Argo CD reached the spoke through its Pod Identity role
#      (platform-smoke-dev Synced/Healthy, cluster Secret without a token);
#   2. ESO on the spoke read Secrets Manager through Pod Identity
#      (ExternalSecret Ready, its SecretStore without an auth block);
#   3. the workload answers (/api/info through a port-forward).
# Writes .local/eks-sandbox/evidence/verify-<UTC time>.txt; never prints a
# secret value. Backs `make eks-session-verify`.
set -eu

[ -f scripts/lab/_lib.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
KUBECTL_BIN=".tools/bin/kubectl"
HUB_KC=".local/kubeconfig-eks-hub" HUB_CTX="eks-hub"
DEV_KC=".local/kubeconfig-eks-dev" DEV_CTX="eks-dev"
APP="platform-smoke-dev" NS="dev"
TIMEOUT="${VERIFY_TIMEOUT:-900}"

hk() { KUBECONFIG="$HUB_KC" "$KUBECTL_BIN" --kubeconfig "$HUB_KC" --context "$HUB_CTX" "$@"; }
dk() { KUBECONFIG="$DEV_KC" "$KUBECTL_BIN" --kubeconfig "$DEV_KC" --context "$DEV_CTX" "$@"; }
for kc in "$HUB_KC" "$DEV_KC"; do [ -f "$kc" ] || { echo "FAIL: $kc missing" >&2; exit 1; }; done

mkdir -p .local/eks-sandbox/evidence
ev=".local/eks-sandbox/evidence/verify-$(date -u +%Y%m%dT%H%M%SZ).txt"
log() { echo "$*" | tee -a "$ev"; }
rc=0

# 1. hub -> spoke
end=$(( $(date +%s) + TIMEOUT )); state=""
while [ "$(date +%s)" -lt "$end" ]; do
  state="$(hk -n argocd get application "$APP" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [ "$state" = "Synced/Healthy" ] && break
  sleep 15
done
if [ "$state" = "Synced/Healthy" ]; then log "OK: $APP Synced/Healthy on the EKS hub"; else log "FAIL: $APP is '${state:-absent}' after ${TIMEOUT}s"; rc=1; fi
cfg_keys="$(hk -n argocd get secret spoke-dev -o jsonpath='{.data.config}' | base64 -d | python3 -I -c 'import json,sys; c=json.load(sys.stdin); print(",".join(sorted(c)), ",".join(sorted(c.get("awsAuthConfig",{}))))')"
case "$cfg_keys" in
  *bearerToken*) log "FAIL: the spoke's cluster Secret carries a bearer token"; rc=1 ;;
  *) log "OK: cluster Secret spoke-dev config keys: $cfg_keys (awsAuthConfig, no token)" ;;
esac

# 2. ESO through Pod Identity
es="$(dk -n "$NS" get externalsecret -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')"
if [ -n "$es" ] && ! printf '%s\n' "$es" | grep -qv '=True$'; then log "OK: ExternalSecret(s) Ready: $(echo $es)"; else log "FAIL: ExternalSecret(s) not Ready: ${es:-none}"; rc=1; fi
auth="$(dk -n "$NS" get secretstore -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.provider.aws.auth}{"\n"}{end}')"
case "$auth" in
  *:) log "OK: SecretStore $(echo "$auth" | tr -d ':') has no auth block (Pod Identity)" ;;
  *) log "FAIL: a SecretStore carries an auth block: $auth"; rc=1 ;;
esac
log "INFO: ESO controller pods: $(dk -n eso-dev get pods -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}')"

# 3. the workload answers
svc="$(dk -n "$NS" get service -l app.kubernetes.io/component=workload -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "$svc" ]; then
  port=19898
  dk -n "$NS" port-forward "service/$svc" "$port:9898" >/dev/null 2>&1 &
  pf=$!
  sleep 5
  info="$(curl -fsS --max-time 10 "http://127.0.0.1:$port/api/info" 2>/dev/null || true)"
  kill "$pf" 2>/dev/null || true
  if [ -n "$info" ]; then log "OK: $svc /api/info answered: $(printf '%s' "$info" | tr -d '\n' | cut -c1-200)"; else log "FAIL: $svc /api/info did not answer"; rc=1; fi
else
  log "FAIL: no workload Service in namespace $NS"; rc=1
fi
log "INFO: nodes (dev): $(dk get nodes -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}/{.metadata.labels.eks\.amazonaws\.com/capacityType} {end}')"

if [ "$rc" -eq 0 ]; then log "session-verify: OK - evidence in $ev"; else log "session-verify: FAILED - evidence in $ev"; fi
exit "$rc"
