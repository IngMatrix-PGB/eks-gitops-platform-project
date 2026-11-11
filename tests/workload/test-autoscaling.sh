#!/bin/sh
# Mutating Phase 2.8.2 runtime test of the prod HPA (ADR-0006 amendment)
# on lab-lite (default) or the lab-multicluster prod spoke
# (LAB_CLUSTER=prod; Argo CD is then the hub's). Requires metrics-server
# on that cluster and a root Application Argo CD reconciles from Git.
# Backs `make workload-test-autoscaling`.
#
#   REVISION       (required) a pushed revision carrying Phase 2.8.2
#   PRE_REVISION   (optional) a pushed revision WITHOUT the HPA (static
#                  replicas: 2). When set, the test first switches the
#                  root Application to it, runs lab/workload/hpa-handover.sh
#                  (unless HANDOVER=0), then switches to REVISION while
#                  sampling the prod Deployment every second - proving the
#                  static -> HPA hand-over never drops below minReplicas.
#                  HANDOVER=0 measures the drop without the hand-over.
#
# Proves: metrics are served and the HPA is ScalingActive; (hand-over);
# under load the HPA scales above minReplicas while Argo CD stays Synced
# and leaves spec.replicas at the HPA's value; without load it scales back
# to minReplicas and never below; a static Deployment is still reconciled
# from Git (lab-lite: a manual scale of dev is reverted); the PDB still
# refuses an immediate second eviction. Removes its load pods on exit.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools
. scripts/argocd/_lib.sh
. scripts/gitops/_lib.sh

case "${LAB_CLUSTER:-lab-lite}" in
  lab-lite) argo_cluster=lab-lite ;;
  prod) argo_cluster=hub ;;
  *) echo "FAIL: run against lab-lite or the prod spoke (LAB_CLUSTER=prod)" >&2; exit 1 ;;
esac
revision="${REVISION:?REVISION is required (a pushed revision carrying Phase 2.8.2)}"
pre_revision="${PRE_REVISION:-}"
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

ns=prod
app=platform-smoke-prod
dep="${app}-standard-workload"
svc="http://${dep}.${ns}.svc.cluster.local:9898"
probe_label="eks-gitops-lab-lite.local/owner=autoscaling-probe"
fail=0
t0="$(date +%s)"
work="$(mktemp -d)"

read -r global_sha_before global_ctx_before <<EOF
$(global_kubeconfig_fingerprint)
EOF

# akubectl: kubectl against the cluster that runs Argo CD for this workload
akubectl() { KUBECONFIG="$(argo_kc)" "$KUBECTL_BIN" --kubeconfig "$(argo_kc)" "$@"; }
argo_kc() { if [ "$argo_cluster" = hub ]; then printf '.local/kubeconfig-hub'; else printf '%s' "$PROJECT_KUBECONFIG"; fi; }
switch_root() { LAB_CLUSTER="$argo_cluster" sh lab/gitops/switch-revision.sh "$1"; }
app_sync() { akubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true; }
spec_replicas() { pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || true; }
hpa_desired() { pkubectl -n "$ns" get hpa "$dep" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true; }

sampler_pid=""
cleanup() {
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null || true
  pkubectl -n "$ns" delete pod -l "$probe_label" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# sample <file> - every second: "<spec.replicas> <readyReplicas>"
start_sampler() {
  ( while :; do
      printf '%s %s\n' "$(spec_replicas)" "$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" >> "$1"
      sleep 1
    done ) &
  sampler_pid=$!
}
stop_sampler() { [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null || true; sampler_pid=""; }
min_col() { awk -v c="$2" '$c ~ /^[0-9]+$/ { if (m == "" || $c < m) m = $c } END { print (m == "" ? "none" : m) }' "$1"; }

# --- 0. metrics are served ---
if LAB_CLUSTER="${LAB_CLUSTER:-lab-lite}" sh lab/metrics-server/status.sh >/dev/null 2>&1; then
  echo "OK: step 0 - metrics-server Available, APIService Available, node metrics served on $PROJECT_CLUSTER_NAME"
else
  echo "FAIL: step 0 - metrics-server is not healthy on $PROJECT_CLUSTER_NAME - run 'make metrics-server-install' first" >&2
  exit 1
fi

# --- 1. hand-over static -> HPA (optional) ---
if [ -n "$pre_revision" ]; then
  switch_root "$pre_revision" >/dev/null
  i=0; while [ "$i" -lt 240 ] && pkubectl -n "$ns" get hpa "$dep" >/dev/null 2>&1; do sleep 5; i=$((i + 5)); done
  [ "$(spec_replicas)" = "2" ] || { echo "FAIL: step 1 - on '$pre_revision' prod is not static at 2 replicas (got $(spec_replicas))" >&2; exit 1; }
  # start from a clean ownership state: release any earlier hand-over
  # (an empty apply by the same manager drops the fields it owned)
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: %s\n  namespace: %s\n' "$dep" "$ns" \
    | pkubectl apply --server-side --field-manager=replicas-hpa-handover -f - >/dev/null
  rep_owners="$(pkubectl -n "$ns" get deployment "$dep" --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"|"}{.fieldsV1.f:spec.f:replicas}{"\n"}{end}' | awk -F'|' '$2 != "" {print $1}' | sort -u | tr '\n' ' ')"
  echo "OK: step 1 - root on '$pre_revision': prod static, spec.replicas=2, no HPA; spec.replicas owners before the switch: $rep_owners"
  if [ "${HANDOVER:-1}" = "1" ]; then
    sh lab/workload/hpa-handover.sh "$ns" "$dep"
  else
    echo "NOTE: step 1 - HANDOVER=0: switching without the hand-over (measuring the drop)"
  fi
  start_sampler "$work/handover.txt"
  switch_root "$revision" >/dev/null
  i=0; while [ "$i" -lt 240 ] && ! pkubectl -n "$ns" get hpa "$dep" >/dev/null 2>&1; do sleep 3; i=$((i + 3)); done
  sleep 45
  stop_sampler
  owner="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.metadata.annotations.eks-gitops-lab-lite\.local/replicas-owner}')"
  min_spec="$(min_col "$work/handover.txt" 1)"; min_ready="$(min_col "$work/handover.txt" 2)"
  samples="$(grep -c . "$work/handover.txt")"
  if [ "${HANDOVER:-1}" != "1" ]; then
    echo "NOTE: step 1 - without the hand-over: min spec.replicas=$min_spec, min Ready=$min_ready over $samples samples (informational)"
  elif [ "$owner" = "hpa" ] && [ "$min_spec" = "2" ] && [ "$min_ready" = "2" ]; then
    echo "OK: step 1 - hand-over to the HPA on '$revision': $samples one-second samples, spec.replicas and Ready never below 2"
  else
    echo "FAIL: step 1 - hand-over: owner='$owner' min spec.replicas=$min_spec min Ready=$min_ready over $samples samples" >&2
    fail=1
  fi
else
  echo "NOTE: step 1 - PRE_REVISION not set; static -> HPA hand-over not measured"
fi

# --- 2. HPA active ---
i=0; active=""
while [ "$i" -lt 180 ]; do
  active="$(pkubectl -n "$ns" get hpa "$dep" -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null || true)"
  [ "$active" = "True" ] && break
  sleep 5; i=$((i + 5))
done
cpu_now="$(pkubectl -n "$ns" get hpa "$dep" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
if [ "$active" = "True" ] && [ -n "$cpu_now" ]; then
  echo "OK: step 2 - HPA ScalingActive=True, current CPU ${cpu_now}% of request, desired $(hpa_desired)"
else
  echo "FAIL: step 2 - HPA ScalingActive='$active' current CPU='$cpu_now'" >&2
  fail=1
fi
[ "$(app_sync)" = "Synced/Healthy" ] || { echo "FAIL: step 2 - $app is $(app_sync)" >&2; fail=1; }

# --- 3. scale up under load; 4. Argo CD does not fight ---
image="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.template.spec.containers[0].image}')"
for n in 1 2 3 4 5; do
  cat <<EOF | pkubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: load-$n
  namespace: $ns
  labels:
    eks-gitops-lab-lite.local/owner: autoscaling-probe
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: "$image"
      command: ["sh", "-c"]
      args:
        - |
          end=\$((\$(date +%s)+420))
          for w in 1 2 3 4 5 6 7 8 9 10 11 12; do
            ( while [ \$(date +%s) -lt \$end ]; do curl -s -o /dev/null --max-time 2 $svc/api/info; done ) &
          done
          wait
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { cpu: 300m, memory: 64Mi } }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
EOF
done
start_sampler "$work/scale.txt"
i=0; peak=2
while [ "$i" -lt 300 ]; do
  d="$(hpa_desired)"; r="$(spec_replicas)"
  [ -n "$r" ] && [ "$r" -gt "$peak" ] && peak="$r"
  [ "${d:-0}" -gt 2 ] && [ "${r:-0}" -gt 2 ] && break
  sleep 5; i=$((i + 5))
done
if [ "$peak" -gt 2 ]; then
  echo "OK: step 3 - under load the HPA scaled prod to $peak replicas in ${i}s (CPU $(pkubectl -n "$ns" get hpa "$dep" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')%)"
else
  echo "FAIL: step 3 - the HPA did not scale above 2 within 300s (desired=$(hpa_desired), CPU=$(pkubectl -n "$ns" get hpa "$dep" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')%)" >&2
  fail=1
fi
stable=0; reads=0
while [ "$reads" -lt 6 ] && [ "$stable" -lt 3 ]; do
  s="$(app_sync)"; r="$(spec_replicas)"; d="$(hpa_desired)"
  if [ "$s" = "Synced/Healthy" ] || [ "$s" = "Synced/Progressing" ]; then
    [ "$r" = "$d" ] && [ "${r:-0}" -gt 2 ] && stable=$((stable + 1)) || stable=0
  else
    stable=0
  fi
  reads=$((reads + 1)); sleep 15
done
if [ "$stable" -ge 3 ]; then
  echo "OK: step 4 - with the HPA above minReplicas, $app stayed Synced and spec.replicas stayed at the HPA's value for 3 consecutive reads (Argo CD does not fight)"
else
  echo "FAIL: step 4 - Argo CD/HPA did not agree: app=$(app_sync) spec.replicas=$(spec_replicas) hpa.desired=$(hpa_desired)" >&2
  fail=1
fi

# --- 5. scale down without load, never below minReplicas ---
pkubectl -n "$ns" delete pod -l "$probe_label" --wait=true --timeout=60s >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 360 ]; do
  [ "$(spec_replicas)" = "2" ] && break
  sleep 5; i=$((i + 5))
done
stop_sampler
low="$(min_col "$work/scale.txt" 1)"
if [ "$(spec_replicas)" = "2" ] && [ "$low" = "2" ]; then
  echo "OK: step 5 - without load prod returned to 2 replicas ${i}s after the load stopped; spec.replicas never went below 2 ($(grep -c . "$work/scale.txt") samples)"
else
  echo "FAIL: step 5 - spec.replicas now $(spec_replicas), lowest sampled $low" >&2
  fail=1
fi

# --- 6. a static Deployment is still reconciled from Git (lab-lite only) ---
if [ "${LAB_CLUSTER:-lab-lite}" = "lab-lite" ]; then
  sdep=platform-smoke-dev-standard-workload
  want="$(pkubectl -n dev get deployment "$sdep" -o jsonpath='{.spec.replicas}')"
  pkubectl -n dev scale deployment "$sdep" --replicas=3 >/dev/null
  i=0
  while [ "$i" -lt 240 ]; do
    [ "$(pkubectl -n dev get deployment "$sdep" -o jsonpath='{.spec.replicas}')" = "$want" ] && break
    sleep 5; i=$((i + 5))
  done
  if [ "$(pkubectl -n dev get deployment "$sdep" -o jsonpath='{.spec.replicas}')" = "$want" ]; then
    echo "OK: step 6 - a manual scale of the static dev Deployment to 3 was reverted to Git's $want by self-heal in ${i}s (replicas are only ignored where the HPA owns them)"
  else
    echo "FAIL: step 6 - static dev Deployment stayed at $(pkubectl -n dev get deployment "$sdep" -o jsonpath='{.spec.replicas}'), Git says $want" >&2
    fail=1
  fi
else
  echo "NOTE: step 6 - the prod spoke has no static Deployment; checked on lab-lite"
fi

# --- 7. PDB still enforced with the HPA ---
pods="$(pkubectl -n "$ns" get pods -l "app.kubernetes.io/instance=${app}" -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}')"
p1="${pods%% *}"; rest="${pods#* }"; p2="${rest%% *}"
evict() { printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"%s"}}' "$1" "$ns" | pkubectl create --raw "/api/v1/namespaces/${ns}/pods/$1/eviction" -f - >/dev/null 2>"$2"; }
if evict "$p1" "$work/e1" && ! evict "$p2" "$work/e2" && grep -qiE '429|disruption budget' "$work/e2"; then
  echo "OK: step 7 - with the HPA, the PDB still allows one eviction and refuses an immediate second (429)"
else
  echo "FAIL: step 7 - PDB eviction behavior changed under the HPA" >&2
  fail=1
fi
i=0; while [ "$i" -lt 180 ] && [ "$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.status.readyReplicas}')" != "2" ]; do sleep 3; i=$((i + 3)); done

read -r global_sha_after global_ctx_after <<EOF
$(global_kubeconfig_fingerprint)
EOF
if [ "$global_sha_before" = "$global_sha_after" ] && [ "$global_ctx_before" = "$global_ctx_after" ]; then
  echo "OK: global kubeconfig unchanged"
else
  echo "FAIL: global kubeconfig changed" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "workload-test-autoscaling: FAILED (${LAB_CLUSTER:-lab-lite}, $(( $(date +%s) - t0 ))s)"; exit 1; fi
echo "workload-test-autoscaling: OK (${LAB_CLUSTER:-lab-lite}, $(( $(date +%s) - t0 ))s)"
