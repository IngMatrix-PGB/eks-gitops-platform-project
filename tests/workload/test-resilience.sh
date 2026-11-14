#!/bin/sh
# Mutating Phase 2.8.1 runtime test of the standard chart's resilience
# contract (ADR-0006 amendment), against the prod workload of one
# cluster: lab-lite (default) or a lab-multicluster spoke
# (LAB_CLUSTER=prod). Requires platform-smoke-prod already deployed by
# Argo CD from a revision carrying Phase 2.8.1 (two replicas, PDB,
# NetworkPolicy) and its ESO source Secret provisioned. Backs
# `make workload-test-resilience`.
#
# Proves:
#   1. a rollout restart under continuous traffic returns zero errors
#      (native preStop sleep + server shutdown timeout + maxUnavailable 0);
#      with RESILIENCE_BASELINE=1 on lab-lite, the same rollout without
#      the preStop/shutdown settings is measured too (informational);
#   2. the PodDisruptionBudget lets one eviction through and refuses an
#      immediate second one (HTTP 429), then allows it again once the
#      replacement is Ready;
#   3. the NetworkPolicy admits http from the same namespace, refuses it
#      from another namespace, denies the workload's egress except DNS,
#      and does not break ESO (a rotated source still reaches the pod's
#      Secret) or the kubelet probes (pods stay Ready);
#   4. both topology spread constraints are on the live Deployment and
#      no replica is Pending;
#   5. Argo CD self-heal recreates a deleted NetworkPolicy and PDB.
# Every probe object it creates is removed on exit. Never prints a
# secret value - only SHA-256 hashes, HTTP codes and counts.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
# shellcheck source=../../scripts/workload/_lib.sh
. scripts/workload/_lib.sh
require_repo_root
require_tools

case "${LAB_CLUSTER:-lab-lite}" in
  lab-lite|prod) : ;;
  *) echo "FAIL: run against lab-lite or the prod spoke (LAB_CLUSTER=prod) - the prod workload is the one with two replicas and a PDB" >&2; exit 1 ;;
esac
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

ns=prod
app=platform-smoke-prod
dep="${app}-standard-workload"
svc_url="http://${dep}.${ns}.svc.cluster.local:9898/readyz"
probe_ns=resilience-probe
probe_label="eks-gitops-lab-lite.local/owner=resilience-probe"
image="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.template.spec.containers[0].image}')"
fail=0
t0="$(date +%s)"

read -r global_sha_before global_ctx_before <<EOF
$(global_kubeconfig_fingerprint)
EOF

cleanup() {
  pkubectl -n "$ns" delete pod -l "$probe_label" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  pkubectl delete namespace "$probe_ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# client_pod <namespace> <name> <shell script> - a Restricted-PSS pod on
# the pinned test client image (Phase 5.1c-1: never the workload's own
# image, which may have no shell).
client_pod() {
  cat <<EOF | pkubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $2
  namespace: $1
  labels:
    eks-gitops-lab-lite.local/owner: resilience-probe
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: c
      image: "$TEST_CLIENT_IMAGE"
      command: ["sh", "-c"]
      args:
        - |
$(printf '%s\n' "$3" | sed 's/^/          /')
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
EOF
}
wait_pod_done() {
  wpd_i=0
  while [ "$wpd_i" -lt "$3" ]; do
    ph="$(pkubectl -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$ph" in Succeeded|Failed) return 0 ;; esac
    sleep 3; wpd_i=$((wpd_i + 3))
  done
  return 1
}
ready_replicas() { pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true; }
wait_ready2() {
  wr_i=0
  while [ "$wr_i" -lt "${1:-180}" ]; do
    [ "$(ready_replicas)" = "2" ] && [ "$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.status.updatedReplicas}/{.status.replicas}')" = "2/2" ] && return 0
    sleep 3; wr_i=$((wr_i + 3))
  done
  return 1
}

# --- 0. preconditions ---
[ "$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.replicas}')" = "2" ] || { echo "FAIL: $dep does not run 2 replicas" >&2; exit 1; }
pkubectl -n "$ns" get poddisruptionbudget "$dep" >/dev/null 2>&1 || { echo "FAIL: PodDisruptionBudget $dep missing - deploy a revision carrying Phase 2.8.1 first" >&2; exit 1; }
pkubectl -n "$ns" get networkpolicy "$dep" >/dev/null 2>&1 || { echo "FAIL: NetworkPolicy $dep missing - deploy a revision carrying Phase 2.8.1 first" >&2; exit 1; }
wait_ready2 120 || { echo "FAIL: $dep is not 2/2 Ready" >&2; exit 1; }
echo "OK: step 0 - $PROJECT_CLUSTER_NAME: $dep 2/2 Ready with its PodDisruptionBudget and NetworkPolicy (image $image)"

# rollout_errors <label> - restarts the Deployment under continuous
# traffic from a same-namespace client; prints "<total> <non-200>".
rollout_errors() {
  name="rollout-client-$1"
  pkubectl -n "$ns" delete pod "$name" --ignore-not-found >/dev/null 2>&1 || true
  client_pod "$ns" "$name" "end=\$((\$(date +%s)+75)); while [ \$(date +%s) -lt \$end ]; do curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 $svc_url || echo 000; sleep 0.2; done"
  pkubectl -n "$ns" wait --for=condition=Ready "pod/$name" --timeout=60s >/dev/null
  sleep 5
  pkubectl -n "$ns" rollout restart "deployment/$dep" >/dev/null
  pkubectl -n "$ns" rollout status "deployment/$dep" --timeout=180s >/dev/null
  wait_pod_done "$ns" "$name" 120 || true
  codes="$(pkubectl -n "$ns" logs "$name" 2>/dev/null)"
  total="$(printf '%s\n' "$codes" | grep -c . || true)"
  bad="$(printf '%s\n' "$codes" | grep -vc '^200$' || true)"
  pkubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  printf '%s %s\n' "$total" "$bad"
}

# --- 1. zero errors during a rollout ---
for run in 1 2; do
  read -r total bad <<EOF
$(rollout_errors "$run")
EOF
  if [ "$total" -ge 100 ] && [ "$bad" = "0" ]; then
    echo "OK: step 1 - rollout restart #$run under traffic: $total requests, 0 errors"
  else
    echo "FAIL: step 1 - rollout restart #$run under traffic: $total requests, $bad non-200" >&2
    fail=1
  fi
  wait_ready2 180 || { echo "FAIL: step 1 - $dep not 2/2 Ready after rollout #$run" >&2; fail=1; }
done
if [ "${RESILIENCE_BASELINE:-0}" = "1" ] && [ "${LAB_CLUSTER:-lab-lite}" = "lab-lite" ]; then
  . scripts/argocd/_lib.sh
  . scripts/gitops/_lib.sh
  gitops_pause_automated_sync "$app"
  pkubectl -n "$ns" patch deployment "$dep" --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/lifecycle"},{"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":30}]' >/dev/null
  pkubectl -n "$ns" set env "deployment/$dep" PODINFO_SERVER_SHUTDOWN_TIMEOUT- >/dev/null
  pkubectl -n "$ns" rollout status "deployment/$dep" --timeout=180s >/dev/null
  wait_ready2 180 || true
  read -r btotal bbad <<EOF
$(rollout_errors baseline)
EOF
  echo "NOTE: step 1 baseline (informational) - same rollout WITHOUT preStop/shutdown timeout: $btotal requests, $bbad non-200"
  gitops_resume_automated_sync "$app"
  pkubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  gitops_wait_for_synced_healthy "$app" 300 >/dev/null || { echo "FAIL: step 1 - $app did not return to Synced/Healthy after the baseline" >&2; fail=1; }
  pre="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.sleep.seconds}')"
  [ "$pre" = "5" ] || { echo "FAIL: step 1 - preStop not restored by self-heal after the baseline (got '$pre')" >&2; fail=1; }
  wait_ready2 180 || true
fi

# --- 2. PodDisruptionBudget ---
evict() {
  printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"%s"}}' "$1" "$ns" \
    | pkubectl create --raw "/api/v1/namespaces/${ns}/pods/$1/eviction" -f - >/dev/null 2>"$2"
}
pods="$(pkubectl -n "$ns" get pods -l "app.kubernetes.io/instance=${app}" -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}')"
p1="${pods%% *}"; rest="${pods#* }"; p2="${rest%% *}"
e1="$(mktemp)"; e2="$(mktemp)"; e3="$(mktemp)"
if evict "$p1" "$e1"; then r1=allowed; else r1="refused: $(head -c 200 "$e1")"; fi
if evict "$p2" "$e2"; then r2=allowed; else r2=refused; fi
too_many="$(grep -ciE '429|disruption budget' "$e2" || true)"
if [ "$r1" = "allowed" ] && [ "$r2" = "refused" ] && [ "$too_many" -ge 1 ]; then
  echo "OK: step 2 - first eviction allowed; an immediate second eviction refused by the PodDisruptionBudget (429)"
else
  echo "FAIL: step 2 - eviction results: first=$r1 second=$r2 (429 seen: $too_many)" >&2
  fail=1
fi
wait_ready2 180 || { echo "FAIL: step 2 - $dep not back to 2/2 Ready after the eviction" >&2; fail=1; }
p3="$(pkubectl -n "$ns" get pods -l "app.kubernetes.io/instance=${app}" -o jsonpath='{.items[0].metadata.name}')"
if evict "$p3" "$e3"; then
  echo "OK: step 2 - once the replacement was Ready, an eviction was allowed again"
else
  echo "FAIL: step 2 - eviction still refused with 2/2 Ready: $(head -c 200 "$e3")" >&2
  fail=1
fi
rm -f "$e1" "$e2" "$e3"
wait_ready2 180 || { echo "FAIL: step 2 - $dep not 2/2 Ready at the end" >&2; fail=1; }

# --- 3. NetworkPolicy ---
pkubectl create namespace "$probe_ns" >/dev/null 2>&1 || true
pkubectl label namespace "$probe_ns" "$probe_label" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
one_shot='for i in 1 2 3; do c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 '"$svc_url"' || true); [ "$c" = 200 ] && { echo 200; exit 0; }; sleep 1; done; echo ${c:-000}'
client_pod "$ns" np-same "$one_shot"
client_pod "$probe_ns" np-other "$one_shot"
wait_pod_done "$ns" np-same 90 || true
wait_pod_done "$probe_ns" np-other 90 || true
same="$(pkubectl -n "$ns" logs np-same 2>/dev/null | tail -1)"
other="$(pkubectl -n "$probe_ns" logs np-other 2>/dev/null | tail -1)"
if [ "$same" = "200" ] && [ "$other" != "200" ]; then
  echo "OK: step 3 - http from the same namespace -> 200; from namespace '$probe_ns' -> blocked ($other)"
else
  echo "FAIL: step 3 - same-namespace=$same other-namespace=$other (expected 200 / blocked)" >&2
  fail=1
fi
wp="$(pkubectl -n "$ns" get pods -l "app.kubernetes.io/instance=${app}" -o jsonpath='{.items[0].metadata.name}')"
# Phase 5.1c-1: probe from an ephemeral container in the workload pod's
# own network namespace (the workload image may have no shell); the
# pod's NetworkPolicy applies to it unchanged. One probe, three lines.
# curl prints 000 itself when it cannot connect; never append a second one.
egress="$(netns_probe "$ns" "$wp" "egress-probe-$(date +%s)" \
  "nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo dns=ok || echo dns=fail; \
   c=\$(curl -sk -o /dev/null -w '%{http_code}' --max-time 4 https://kubernetes.default.svc:443/livez); echo api=\${c:-000}; \
   c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://${dep}.${ns}.svc.cluster.local:9898/readyz); echo ext=\${c:-000}" 90 || true)"
dns="$(printf '%s\n' "$egress" | sed -n 's/^dns=//p')"; dns="${dns:-fail}"
api="$(printf '%s\n' "$egress" | sed -n 's/^api=//p')"; api="${api:-unknown}"
ext="$(printf '%s\n' "$egress" | sed -n 's/^ext=//p')"; ext="${ext:-unknown}"
if [ "$dns" = "ok" ] && [ "$api" = "000" ] && [ "$ext" = "000" ]; then
  echo "OK: step 3 - workload egress: DNS resolves; the API server and even its own Service are unreachable (egress is DNS-only)"
else
  echo "FAIL: step 3 - workload egress: dns=$dns api=$api own-service=$ext (expected ok/000/000)" >&2
  fail=1
fi
target="${dep}-secret"
tsha() { pkubectl -n "$ns" get secret "$target" -o jsonpath='{.data.message}' 2>/dev/null | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
vfile="$(mktemp)"; chmod 600 "$vfile"
printf 'lab-%s-%s' "$(date +%s)" "$(head -c 16 /dev/urandom | shasum -a 256 | cut -c1-24)" > "$vfile"
want="$(shasum -a 256 "$vfile" | awk '{print $1}')"
sh lab/eso/provision-source-secret.sh prod --rotate < "$vfile" >/dev/null
rm -f "$vfile"
i=0; while [ "$i" -lt 150 ] && [ "$(tsha)" != "$want" ]; do sleep 5; i=$((i + 5)); done
if [ "$(tsha)" = "$want" ]; then
  echo "OK: step 3 - ESO still syncs under the NetworkPolicy: the rotated source reached $target in ${i}s"
else
  echo "FAIL: step 3 - the rotated source did not reach $target within 150s" >&2
  fail=1
fi
[ "$(ready_replicas)" = "2" ] && echo "OK: step 3 - kubelet probes unaffected by the NetworkPolicy (2/2 Ready)" || { echo "FAIL: step 3 - replicas not Ready under the NetworkPolicy" >&2; fail=1; }

# --- 4. topology spread ---
keys="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{range .spec.template.spec.topologySpreadConstraints[*]}{.topologyKey}={.whenUnsatisfiable} {end}')"
pending="$(pkubectl -n "$ns" get pods -l "app.kubernetes.io/instance=${app}" --field-selector=status.phase=Pending -o name | grep -c . || true)"
if [ "$keys" = "kubernetes.io/hostname=ScheduleAnyway topology.kubernetes.io/zone=ScheduleAnyway " ] && [ "$pending" = "0" ]; then
  echo "OK: step 4 - live Deployment carries hostname + zone spread (ScheduleAnyway); no replica Pending"
else
  echo "FAIL: step 4 - spread constraints '$keys', pending=$pending" >&2
  fail=1
fi

# --- 5. self-heal recreates the new kinds ---
for kind in networkpolicy poddisruptionbudget; do
  uid0="$(pkubectl -n "$ns" get "$kind" "$dep" -o jsonpath='{.metadata.uid}')"
  pkubectl -n "$ns" delete "$kind" "$dep" >/dev/null
  i=0; uid1=""
  while [ "$i" -lt 240 ]; do
    uid1="$(pkubectl -n "$ns" get "$kind" "$dep" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    [ -n "$uid1" ] && [ "$uid1" != "$uid0" ] && break
    sleep 5; i=$((i + 5))
  done
  if [ -n "$uid1" ] && [ "$uid1" != "$uid0" ]; then
    echo "OK: step 5 - deleted $kind/$dep recreated by Argo CD self-heal in ${i}s"
  else
    echo "FAIL: step 5 - $kind/$dep not recreated within 240s" >&2
    fail=1
  fi
done

read -r global_sha_after global_ctx_after <<EOF
$(global_kubeconfig_fingerprint)
EOF
if [ "$global_sha_before" = "$global_sha_after" ] && [ "$global_ctx_before" = "$global_ctx_after" ]; then
  echo "OK: global kubeconfig unchanged"
else
  echo "FAIL: global kubeconfig changed" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "workload-test-resilience: FAILED (${LAB_CLUSTER:-lab-lite}, $(( $(date +%s) - t0 ))s)"
  exit 1
fi
echo "workload-test-resilience: OK (${LAB_CLUSTER:-lab-lite}, $(( $(date +%s) - t0 ))s)"
