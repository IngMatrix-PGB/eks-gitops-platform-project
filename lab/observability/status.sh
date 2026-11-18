#!/bin/sh
# Read-only status of the observability stack on one lab-multicluster
# member (Phase 6.1b). Backs `make obs-status LAB_CLUSTER=hub|dev|uat|prod`.
# Exits non-zero on the first gap it finds in each section.
#
#   hub    releases deployed and Ready; through a port-forward to the hub
#          Prometheus: a request without credentials gets 401 (query and
#          remote write); with the self-scrape user, which clusters have
#          series (`count by (cluster) (up)`); EXPECT_CLUSTERS="hub spoke-dev
#          ..." makes each listed cluster mandatory; every rule loaded and
#          healthy; the Argo CD application controller scraped. Grafana: healthy, its
#          provisioned datasource answers, the platform dashboards exist.
#   spoke  release deployed and Ready; over STATUS_WINDOW seconds (default
#          75) the agent sent samples to the hub and none was refused.
#
# Credentials are read from the Secrets into a mode-600 netrc file in a
# mktemp directory, used by curl, and removed; never printed.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. lab/multicluster/_lib.sh
. scripts/observability/_lib.sh
role="$(obs_role)"
require_tools
require_helm
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

work="$(mktemp -d)"
pf_pid=""
cleanup() { [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT INT TERM
umask 077
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# port_forward <target> <remote-port> - sets local_port; waits until open.
port_forward() {
  [ -n "$pf_pid" ] && { kill "$pf_pid" 2>/dev/null || true; pf_pid=""; }
  local_port="$(awk 'BEGIN { srand(); print 20000 + int(rand() * 20000) }')"
  pkubectl -n "$OBS_NAMESPACE" port-forward "$1" "${local_port}:$2" >/dev/null 2>&1 &
  pf_pid=$!
  i=0
  while [ "$i" -lt 30 ]; do
    curl -s -o /dev/null "http://127.0.0.1:${local_port}/" 2>/dev/null && return 0
    i=$((i + 1)); sleep 1
  done
  echo "FAIL: port-forward to $1:$2 did not open" >&2; return 1
}

# netrc <user> <password-file> - writes $work/netrc for 127.0.0.1.
netrc() {
  { printf 'machine 127.0.0.1 login %s password ' "$1"; cat "$2"; printf '\n'; } > "$work/netrc"
}

check_release() {
  if phelm status "$1" -n "$OBS_NAMESPACE" -o json 2>/dev/null | grep -q '"status":"deployed"'; then
    ok "release '$1' deployed"
  else
    bad "release '$1' not deployed"
  fi
}

check_ready() {
  cr_not="$(pkubectl -n "$OBS_NAMESPACE" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].ready}{"\n"}{end}' | awk '$0 ~ /false/ || NF < 2 { print $1 }')"
  if [ -z "$cr_not" ]; then ok "every pod in $OBS_NAMESPACE Ready"; else bad "pods not Ready: $(echo "$cr_not" | tr '\n' ' ')"; fi
}

check_release "$OBS_RELEASE"
if [ "$role" = hub ]; then check_release "$OBS_GRAFANA_RELEASE"; fi
check_ready

if [ "$role" = hub ]; then
  port_forward "svc/${OBS_HUB_QUERY_SVC}" 80
  base="http://127.0.0.1:${local_port}"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base/api/v1/query?query=up")"
  [ "$code" = 401 ] && ok "query without credentials: 401" || bad "query without credentials: $code (want 401)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/x-protobuf' --data-binary 'x' "$base/api/v1/write")"
  [ "$code" = 401 ] && ok "remote write without credentials: 401" || bad "remote write without credentials: $code (want 401)"
  obs_secret_key pkubectl "$OBS_SECRET_SELF" password > "$work/pw" || { bad "Secret $OBS_SECRET_SELF unreadable"; exit 1; }
  netrc hub "$work/pw"; rm -f "$work/pw"
  curl -s --netrc-file "$work/netrc" -G "$base/api/v1/query" --data-urlencode 'query=count by (cluster) (up)' > "$work/q.json"
  clusters="$(jq -r '.data.result[] | "\(.metric.cluster)=\(.value[1])"' "$work/q.json" 2>/dev/null | sort | tr '\n' ' ')"
  if [ -n "$clusters" ]; then ok "series by cluster (targets): $clusters"; else bad "no series by cluster (response: $(head -c 200 "$work/q.json"))"; fi
  # Phase 6.1c: every rule file in platform/observability/rules is loaded
  # and every rule evaluates without error.
  curl -s --netrc-file "$work/netrc" "$base/api/v1/rules" > "$work/rules.json"
  n_rules="$(jq '[.data.groups[].rules[]] | length' "$work/rules.json" 2>/dev/null || echo 0)"
  n_bad="$(jq '[.data.groups[].rules[] | select(.health != "ok")] | length' "$work/rules.json" 2>/dev/null || echo 1)"
  want_rules="$(cat platform/observability/rules/*.rules.yml | grep -cE '^[[:space:]]+- (record|alert): ')"
  [ "$n_rules" = "$want_rules" ] && [ "$n_bad" = 0 ] && ok "$n_rules rules loaded, all healthy" || bad "rules loaded: $n_rules (want $want_rules), unhealthy: $n_bad"
  curl -s --netrc-file "$work/netrc" -G "$base/api/v1/query" --data-urlencode 'query=up{job="argocd-application-controller"}' \
    | jq -e '.data.result[0].value[1] == "1"' >/dev/null && ok "Argo CD application controller scraped (up=1)" || bad "Argo CD application controller not scraped"
  for want in ${EXPECT_CLUSTERS:-}; do
    case " $clusters" in *" ${want}="*) ok "cluster '$want' present" ;; *) bad "cluster '$want' has no series in the hub" ;; esac
  done

  # Phase 6.1d: Loki through its gateway. Without credentials a push gets
  # 401; with the "hub" user, which clusters have log streams.
  port_forward "svc/${OBS_LOKI_GATEWAY_SVC}" 80
  lbase="http://127.0.0.1:${local_port}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{"streams":[]}' "$lbase/loki/api/v1/push")"
  [ "$code" = 401 ] && ok "log push without credentials: 401" || bad "log push without credentials: $code (want 401)"
  log_clusters="$(curl -s --netrc-file "$work/netrc" "$lbase/loki/api/v1/label/cluster/values" | jq -r '.data[]?' | sort | tr '\n' ' ')"
  if [ -n "$log_clusters" ]; then ok "log streams by cluster: $log_clusters"; else bad "no log streams in Loki"; fi
  for want in ${EXPECT_CLUSTERS:-}; do
    case "$want" in hub) continue ;; esac
    case " $log_clusters" in *" $want "*) ok "cluster '$want' has logs" ;; *) bad "cluster '$want' has no logs in Loki" ;; esac
  done

  port_forward "svc/${OBS_GRAFANA_RELEASE}" 80
  gbase="http://127.0.0.1:${local_port}"
  curl -s "$gbase/api/health" | jq -e '.database == "ok"' >/dev/null && ok "Grafana healthy" || bad "Grafana not healthy"
  obs_secret_key pkubectl "$OBS_SECRET_GRAFANA_ADMIN" admin-password > "$work/pw" || { bad "Secret $OBS_SECRET_GRAFANA_ADMIN unreadable"; exit 1; }
  netrc admin "$work/pw"; rm -f "$work/pw"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$gbase/api/search")"
  [ "$code" = 401 ] && ok "Grafana API without credentials: 401 (no anonymous access)" || bad "Grafana API without credentials: $code (want 401)"
  ds="$(curl -s --netrc-file "$work/netrc" "$gbase/api/datasources/uid/${OBS_GRAFANA_DS_UID}/health" | jq -r '.status // empty')"
  [ "$ds" = OK ] && ok "Grafana datasource '${OBS_GRAFANA_DS_UID}' reaches the hub Prometheus" || bad "Grafana datasource health: '${ds}'"
  lds="$(curl -s --netrc-file "$work/netrc" "$gbase/api/datasources/uid/${OBS_GRAFANA_LOKI_DS_UID}/health" | jq -r '.status // empty')"
  [ "$lds" = OK ] && ok "Grafana datasource '${OBS_GRAFANA_LOKI_DS_UID}' reaches Loki" || bad "Grafana Loki datasource health: '${lds}'"
  n="$(curl -s --netrc-file "$work/netrc" "$gbase/api/search?tag=platform" | jq 'length')"
  want_n="$(ls platform/observability/dashboards/*.json | wc -l | tr -d ' ')"
  [ "$n" = "$want_n" ] && ok "Grafana has the $want_n platform dashboards" || bad "Grafana platform dashboards: $n (want $want_n)"
else
  # Two readings of the agent's own counters, STATUS_WINDOW seconds apart
  # (default 75, more than two 30s scrape intervals): samples must have
  # been sent in the window and none refused in it. Totals alone would
  # keep reporting failures from before a fix.
  port_forward "deploy/${OBS_RELEASE}-prometheus-server" 9090
  window="${STATUS_WINDOW:-75}"
  counters() {
    curl -s "http://127.0.0.1:${local_port}/metrics" | awk '
      /^prometheus_remote_storage_samples_total[{ ]/ { s += $NF }
      /^prometheus_remote_storage_samples_failed_total[{ ]/ { f += $NF }
      END { printf "%d %d\n", s, f }'
  }
  c0="$(counters)"; sleep "$window"; c1="$(counters)"
  sent0="${c0% *}"; failed0="${c0#* }"; sent1="${c1% *}"; failed1="${c1#* }"
  if [ $((sent1 - sent0)) -gt 0 ]; then ok "agent sent $((sent1 - sent0)) samples to the hub in the last ${window}s ($sent1 in total)"; else bad "agent sent no samples in the last ${window}s"; fi
  if [ $((failed1 - failed0)) -eq 0 ]; then ok "no remote-write sample refused in the window ($failed1 refused since the agent started)"; else bad "$((failed1 - failed0)) remote-write samples refused in the window (credential or hub address?)"; fi

  # Phase 6.1d: the log agent. Release deployed, the DaemonSet's pod Ready,
  # and its own counters: no output error and no dropped retry, totals
  # since it started (it only sends when the workload logs).
  if phelm status "$OBS_LOGS_RELEASE" -n "$OBS_LOGS_NAMESPACE" -o json 2>/dev/null | grep -q '"status":"deployed"'; then ok "release '$OBS_LOGS_RELEASE' deployed"; else bad "release '$OBS_LOGS_RELEASE' not deployed"; fi
  lr="$(pkubectl -n "$OBS_LOGS_NAMESPACE" get daemonset "$OBS_LOGS_RELEASE-fluent-bit" -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)"
  case "$lr" in ""|0/*|*/0) bad "log agent DaemonSet not ready ($lr)" ;; *) [ "${lr%/*}" = "${lr#*/}" ] && ok "log agent Ready on every node ($lr)" || bad "log agent DaemonSet $lr Ready" ;; esac
  pkubectl -n "$OBS_LOGS_NAMESPACE" port-forward "daemonset/$OBS_LOGS_RELEASE-fluent-bit" "$((local_port + 1)):2020" >/dev/null 2>&1 &
  lpf=$!
  i=0; until curl -s -o /dev/null "http://127.0.0.1:$((local_port + 1))/" || [ $i -gt 30 ]; do i=$((i + 1)); sleep 1; done
  curl -s "http://127.0.0.1:$((local_port + 1))/api/v2/metrics/prometheus" > "$work/fb"
  kill "$lpf" 2>/dev/null || true; wait "$lpf" 2>/dev/null || true
  fb_sent="$(awk '/^fluentbit_output_proc_records_total[{ ]/ { s += $NF } END { printf "%d", s }' "$work/fb")"
  fb_err="$(awk '/^fluentbit_output_(errors|retries_failed)_total[{ ]/ { s += $NF } END { printf "%d", s }' "$work/fb")"
  ok "log agent sent $fb_sent records to the hub"
  [ "${fb_err:-0}" -eq 0 ] && ok "log agent: no output error or dropped retry" || bad "log agent: $fb_err output errors or dropped retries (credential or hub address?)"
fi

if [ "$fail" -ne 0 ]; then echo "obs-status: FAILED ($role on '$PROJECT_CLUSTER_NAME')"; exit 1; fi
echo "obs-status: OK ($role on '$PROJECT_CLUSTER_NAME')"
