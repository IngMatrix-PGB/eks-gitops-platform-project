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

# --- Phase 6.1c: rules and their unit tests ----------------------------------
long_only() { mutate "$1/rules/slo-smoke.rules.yml" 's/cluster:smoke_http_errors:ratio_rate5m > (14.4 \* 0.005)/cluster:smoke_http_errors:ratio_rate1h > (14.4 * 0.005)/'; }
run_case "a fast-burn alert without its short window fails its unit tests" reject long_only
no_cluster() { mutate "$1/rules/slo-smoke.rules.yml" 's/sum by (cluster) \(.*code=~"5.."}\[5m\]\)/sum \1/'; }
run_case "an error ratio that drops the cluster label fails its unit tests" reject no_cluster
any_route() { mutate "$1/rules/slo-smoke.rules.yml" 's/route=~"\/|\/api\/info",code=~"5.."/code=~"5.."/g'; }
run_case "an SLI that counts errors on every route fails its unit tests" reject any_route
short_for() { mutate "$1/rules/argocd.rules.yml" 's/for: 10m/for: 1m/'; }
run_case "a Degraded alert that fires after 1 minute fails its unit tests" reject short_for
untested() { printf '      - alert: ArgoCDUntested\n        expr: vector(1)\n' >> "$1/rules/argocd.rules.yml"; }
run_case "an alert no test expects to fire is rejected" reject untested
no_tests() { rm "$1/rules/tests/argocd.test.yml"; }
run_case "a rule file without unit tests is rejected" reject no_tests
not_loaded() { mutate "$1/prometheus-hub.yml" 's|  - /etc/config/\*.rules.yml|  - /etc/config/none.yml|'; }
run_case "a hub config that does not load the rule files is rejected" reject not_loaded

# --- Phase 6.1d: the logs dashboard --------------------------------------------
loki_mixed() { mutate_dash "$1/dashboards/logs.json" '.panels[0].targets[0].datasource.uid = "hub-prometheus"'; }
run_case "a query on another datasource than its panel is rejected" reject loki_mixed
loki_any() { mutate_dash "$1/dashboards/logs.json" '.panels[2].targets[0].expr = "{namespace=~\"$namespace\"}"'; }
run_case "a LogQL query without the cluster selector is rejected" reject loki_any
loki_foreign() { mutate_dash "$1/dashboards/logs.json" '.panels[2].datasource.uid = "elsewhere" | .panels[2].targets[0].datasource.uid = "elsewhere"'; }
run_case "a logs panel on a datasource that is not provisioned is rejected" reject loki_foreign

echo ""
echo "test-check-observability: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-check-observability: FAILED"; exit 1; }
echo "test-check-observability: OK"
