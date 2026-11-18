#!/bin/sh
# Regression tests for scripts/validate/check-observability.sh (Phase
# 6.1b): the checker, unmodified, against throwaway copies of
# platform/observability/, each with one mutation. Backs
# `make check-observability-regression`. Touches nothing outside one
# mktemp -d root.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$here/scripts/validate/check-observability.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0
n=0
# $1=description  $2=accept|reject  $3=setup function (gets the fixture dir)
run_case() {
  n=$((n + 1)); fx="$root/case$n"
  mkdir -p "$fx/platform"
  cp -R "$here/platform/observability" "$fx/platform/"
  "$3" "$fx/platform/observability"
  if (cd "$here" && OBS_CHECK_ROOT="$fx" sh "$checker" > "$fx.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$fx.out" >&2; fail=$((fail + 1)); fi
}
# $1=file $2=sed expression; a mutation that changes nothing fails loudly.
mutate() {
  cp "$1" "$1.orig"
  sed -i.bak -e "$2" "$1" && rm -f "$1.bak"
  if cmp -s "$1" "$1.orig"; then echo "FAIL: mutation '$2' changed nothing in $1" >&2; exit 1; fi
  rm -f "$1.orig"
}
# $1=dashboard file $2=jq filter
mutate_dash() { jq "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }

real() { :; }
run_case "the real configs and dashboards are accepted" accept real

other_ds() { mutate_dash "$1/dashboards/smoke-workload.json" '.panels[0].targets[0].datasource.uid = "other"'; }
run_case "a dashboard query on another datasource is rejected" reject other_ds
bad_promql() { mutate_dash "$1/dashboards/clusters-overview.json" '.panels[2].targets[0].expr = "sum by (cluster) (rate(container_cpu_usage_seconds_total[5m]"'; }
run_case "a dashboard query that does not parse is rejected" reject bad_promql
dup_uid() { mutate_dash "$1/dashboards/smoke-workload.json" '.uid = "platform-clusters"'; }
run_case "two dashboards with the same uid are rejected" reject dup_uid
bad_json() { printf '{"uid": "x",' > "$1/dashboards/broken.json"; }
run_case "a dashboard that is not valid JSON is rejected" reject bad_json
no_query() { mutate_dash "$1/dashboards/smoke-workload.json" '.panels[1].targets = []'; }
run_case "a panel without a query is rejected" reject no_query
any_ns() { mutate "$1/prometheus-spoke.yml" '/names: \["@ENVIRONMENT@"\]/d'; }
run_case "a spoke that discovers workload pods in every namespace is rejected" reject any_ns
any_port() { mutate "$1/prometheus-spoke.yml" 's/^        regex: metrics$/        regex: .+/'; }
run_case "a spoke that scrapes any container port is rejected" reject any_port
inline_pw() { mutate "$1/prometheus-spoke.yml" 's|      password_file: /etc/remote-write/password|      password: hunter2|'; }
run_case "a remote-write password written inline is rejected" reject inline_pw
hub_bad() { mutate "$1/prometheus-hub.yml" 's/^  scrape_interval: 30s$/  scrape_interval: thirty/'; }
run_case "a hub config promtool rejects is rejected" reject hub_bad
no_label() { mutate "$1/prometheus-spoke.yml" '/^    environment: "@ENVIRONMENT@"$/d'; }
run_case "a spoke without the environment label is rejected" reject no_label

echo ""
echo "test-check-observability: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-check-observability: FAILED"; exit 1; }
echo "test-check-observability: OK"
