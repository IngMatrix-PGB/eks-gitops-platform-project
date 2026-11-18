#!/bin/sh
# Phase 6.1b (ADR-0021): offline check of the observability configuration
# kept in platform/observability/. Part of `make validate`; needs only the
# pinned promtool (make tools-install), jq and awk - no chart, no cluster.
#
#   - the hub config and each spoke's config (dev, uat, prod, placeholders
#     filled) pass `promtool check config` (spoke in agent mode), lint fatal;
#   - each spoke labels its series cluster=spoke-<env>, environment=<env>,
#     scrapes the workload only in its own namespace and on the port named
#     "metrics", and authenticates its remote write with a password file;
#   - neither config carries a credential inline (no "password:" or
#     "credentials:" value; files only);
#   - every dashboard is valid JSON with a unique uid and a "Platform / "
#     title, uses only the provisioned datasource UID (dashboard, panels,
#     targets, variables), and every query parses (promtool check rules on
#     the expressions, with $cluster replaced).
#
# OBS_CHECK_ROOT (default ".") lets the regression test run this script
# unmodified against a mutated copy.
set -eu

root="${OBS_CHECK_ROOT:-.}"
promtool="${PROMTOOL_BIN:-.tools/bin/promtool}"
[ -x "$promtool" ] || { echo "FAIL: $promtool not found - run 'make tools-install'" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq not found" >&2; exit 1; }
here="$(pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

DS_UID="$(sed -n 's/^OBS_GRAFANA_DS_UID="\(.*\)"$/\1/p' "$here/scripts/observability/_lib.sh")"
[ -n "$DS_UID" ] || { echo "FAIL: OBS_GRAFANA_DS_UID not found in scripts/observability/_lib.sh" >&2; exit 1; }
cfg_dir="$root/platform/observability"
dash_dir="$cfg_dir/dashboards"

# --- Prometheus configs ---------------------------------------------------------
# The same placeholder filling as the install (obs_write_prom_config).
hub_url="$(sed -n 's/^OBS_HUB_WRITE_URL="\(.*\)"$/\1/p' "$here/scripts/observability/_lib.sh" | sed 's/\${OBS_HUB_NODEPORT}/30090/')"
if "$promtool" check config --syntax-only --lint-fatal "$cfg_dir/prometheus-hub.yml" > "$work/out" 2>&1; then
  ok "hub Prometheus config passes promtool check config"
else
  bad "hub Prometheus config: $(tail -3 "$work/out" | tr '\n' ' ')"
fi
for env in dev uat prod; do
  f="$work/spoke-$env.yml"
  sed -e "s|@CLUSTER@|spoke-$env|g" -e "s|@ENVIRONMENT@|$env|g" -e "s|@HUB_WRITE_URL@|$hub_url|g" "$cfg_dir/prometheus-spoke.yml" > "$f"
  if grep -q '@[A-Z_]*@' "$f"; then bad "spoke-$env: unfilled placeholder"; continue; fi
  if "$promtool" check config --agent --syntax-only --lint-fatal "$f" > "$work/out" 2>&1; then :; else
    bad "spoke-$env Prometheus config: $(tail -3 "$work/out" | tr '\n' ' ')"; continue
  fi
  grep -qF "cluster: \"spoke-$env\"" "$f" && grep -qF "environment: \"$env\"" "$f" \
    || bad "spoke-$env: external_labels cluster/environment missing"
  awk '/job_name: workload/{f=1} f&&/job_name:/&&!/workload/{f=0} f' "$f" > "$work/workload-$env"
  grep -qF "names: [\"$env\"]" "$work/workload-$env" && grep -qE '^[[:space:]]+regex: metrics$' "$work/workload-$env" \
    || bad "spoke-$env: the workload job is not limited to namespace '$env' and the port named 'metrics'"
  grep -qF 'password_file: /etc/remote-write/password' "$f" || bad "spoke-$env: remote write not authenticated with a password file"
done
[ "$fail" -eq 0 ] && ok "spoke configs (dev, uat, prod) pass promtool in agent mode, labeled and scoped per environment"
for f in "$cfg_dir/prometheus-hub.yml" "$cfg_dir/prometheus-spoke.yml"; do
  if grep -nE '^[[:space:]]*(password|credentials|bearer_token):[[:space:]]*[^[:space:]#]' "$f" > "$work/inline"; then
    bad "$(basename "$f"): inline credential at line(s) $(cut -d: -f1 "$work/inline" | tr '\n' ' ')"
  fi
done

# --- dashboards ------------------------------------------------------------------
n=0
: > "$work/uids"
printf 'groups:\n  - name: dashboard-queries\n    rules:\n' > "$work/rules.yml"
for d in "$dash_dir"/*.json; do
  [ -f "$d" ] || continue
  n=$((n + 1)); b="$(basename "$d")"
  if ! jq -e . "$d" >/dev/null 2>&1; then bad "$b: not valid JSON"; continue; fi
  jq -r '.uid // ""' "$d" >> "$work/uids"
  jq -e '.uid and (.title | startswith("Platform / "))' "$d" >/dev/null || bad "$b: needs a uid and a title starting 'Platform / '"
  others="$(jq -r --arg u "$DS_UID" '[.. | objects | select(has("datasource")) | .datasource | if type == "object" then .uid else . end | select(. != $u)] | unique | join(",")' "$d")"
  [ -z "$others" ] || bad "$b: datasource other than '$DS_UID': $others"
  jq -e '[.panels[] | .targets // [] | length] | all(. > 0)' "$d" >/dev/null || bad "$b: a panel without a query"
  # Each query becomes a recording rule, so promtool parses it.
  jq -r '.panels[].targets[]?.expr' "$d" | sed 's/\$cluster/.+/g' | awk -v n="$n" '
    { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "      - record: dashboard_query_%d_%d\n        expr: \"%s\"\n", n, NR, $0 }' >> "$work/rules.yml"
done
[ "$n" -gt 0 ] || bad "no dashboard in $dash_dir"
dup="$(sort "$work/uids" | uniq -d | tr '\n' ' ')"
[ -z "$dup" ] || bad "duplicate dashboard uid(s): $dup"
if "$promtool" check rules --lint=none "$work/rules.yml" > "$work/out" 2>&1; then
  ok "$n dashboards: valid JSON, unique uids, only datasource '$DS_UID', every query parses ($(grep -c 'record:' "$work/rules.yml") queries)"
else
  bad "dashboard queries do not parse: $(grep -iE 'error|failed' "$work/out" | head -3 | tr '\n' ' ')"
fi

if [ "$fail" -ne 0 ]; then echo "check-observability: FAILED"; exit 1; fi
echo "check-observability: OK"
