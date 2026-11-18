#!/bin/sh
# Fail-closed, idempotent install of the observability stack on one
# lab-multicluster member (Phase 6.1b, ADR-0021). Backs
# `make obs-install LAB_CLUSTER=hub|dev|uat|prod`. Install the hub first.
#
#   hub    namespace monitoring; Secrets for the self-scrape user, the
#          Grafana datasource user and the Grafana admin (generated once,
#          kept on re-runs); the web config with one bcrypt hash per user;
#          the dashboards ConfigMap; releases obs (Prometheus + Alertmanager)
#          and obs-grafana.
#   spoke  namespace monitoring; its own remote-write password (generated
#          once) in the Secret obs-remote-write on the spoke, its bcrypt hash
#          as user spoke-<env> on the hub; release obs (agent +
#          kube-state-metrics).
#
# Releases: same chart and values -> no helm call; changed values ->
# upgrade; another chart or a release not "deployed" -> fail closed.
# A first install refuses when Docker has less free memory than the role's
# floor (OBS_SKIP_MEMORY_CHECK=1 overrides, printed). No credential is
# printed, passed on argv or written outside a mktemp directory.
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
require_obs_charts
require_htpasswd
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

hk() { ckubectl hub "$@"; }
if [ "$role" = spoke ]; then
  lab_mc_identity hub || { echo "FAIL: the hub cluster is not up ($LAB_MC_IDENTITY_CASE) - a spoke writes to it" >&2; exit 1; }
  obs_secret_key hk "$OBS_SECRET_WEB" users >/dev/null 2>&1 || { echo "FAIL: the hub's stack is not installed - run 'make obs-install LAB_CLUSTER=hub' first" >&2; exit 1; }
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
umask 077

# --- memory gate (first install only) ------------------------------------
release_present() { phelm status "$1" -n "$OBS_NAMESPACE" >/dev/null 2>&1; }
if ! release_present "$OBS_RELEASE"; then
  need="$OBS_SPOKE_MIB"; [ "$role" = hub ] && need="$OBS_HUB_MIB"
  free_mib="$(lab_mc_docker_free_mib)" || { echo "FAIL: could not read Docker memory" >&2; exit 1; }
  if [ "${OBS_SKIP_MEMORY_CHECK:-}" = "1" ]; then
    echo "obs-install: WARNING - memory check skipped by OBS_SKIP_MEMORY_CHECK=1 (~${free_mib} MiB free, floor ${need} MiB)"
  elif [ "$free_mib" -lt "$need" ]; then
    echo "FAIL: obs-install: Docker has ~${free_mib} MiB free; the ${role} stack needs ~${need} MiB. Nothing was installed." >&2
    exit 1
  else
    echo "OK: memory check - ~${free_mib} MiB free, floor ${need} MiB for the ${role} stack"
  fi
fi

obs_ensure_namespace pkubectl

# ensure_password <kubectl-fn> <secret> <key> <out-file> - reads the
# password kept in <secret>/<key>, or generates and stores one. Returns
# 10 when it generated a new one.
ensure_password() {
  if obs_secret_key "$1" "$2" "$3" > "$4" 2>/dev/null; then return 0; fi
  # Called in an || list, where set -e is off: every step checks itself.
  mkdir -p "$work/s-$2" || return 1
  obs_random_password > "$work/s-$2/$3" || return 1
  [ -s "$work/s-$2/$3" ] || { echo "FAIL: could not generate a password for $2" >&2; return 1; }
  obs_apply_secret "$1" "$2" "$work/s-$2" || { echo "FAIL: could not write Secret $2" >&2; return 1; }
  cp "$work/s-$2/$3" "$4" || return 1
  return 10
}

# upgrade_release <name> <chart-tgz> <chart-name-version> <values-sha> <helm args...>
upgrade_release() {
  ur_name="$1"; ur_tgz="$2"; ur_chart="$3"; ur_sha="$4"; shift 4
  if release_present "$ur_name"; then
    ur_json="$(phelm status "$ur_name" -n "$OBS_NAMESPACE" -o json 2>/dev/null | sed 's/,"notes":.*//')"
    ur_status="$(printf '%s' "$ur_json" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    ur_desc="$(printf '%s' "$ur_json" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"
    ur_have="$(phelm list -n "$OBS_NAMESPACE" -o json 2>/dev/null | tr '{' '\n' | grep "\"name\":\"${ur_name}\"" | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')"
    [ "$ur_have" = "$ur_chart" ] || { echo "FAIL: release '$ur_name' runs chart '$ur_have', not $ur_chart - refusing to reconcile automatically" >&2; exit 1; }
    [ "$ur_status" = "deployed" ] || { echo "FAIL: release '$ur_name' status '$ur_status' is not 'deployed' - refusing to reconcile automatically" >&2; exit 1; }
    if [ "$ur_desc" = "values-sha256:${ur_sha}" ]; then
      echo "OK: release '$ur_name' already at the pinned chart and values on '$PROJECT_CLUSTER_NAME' - no-op"
      return 0
    fi
    echo "obs-install: release '$ur_name' values changed - upgrading"
  else
    echo "obs-install: installing release '$ur_name' ($ur_chart) on '$PROJECT_CLUSTER_NAME'"
  fi
  phelm upgrade --install "$ur_name" "$ur_tgz" --namespace "$OBS_NAMESPACE" "$@" \
    --description "values-sha256:${ur_sha}" --wait --timeout 5m >/dev/null
  echo "OK: release '$ur_name' deployed and Ready"
}

if [ "$role" = hub ]; then
  rc=0; ensure_password hk "$OBS_SECRET_SELF" password "$work/pw-hub" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || exit 1
  if [ "$rc" -eq 10 ] || ! obs_hub_has_user hk hub; then obs_hub_set_user hk hub "$work/pw-hub"; echo "OK: hub user 'hub' (self-scrape) set"; fi
  rc=0; ensure_password hk "$OBS_SECRET_GRAFANA_DS" OBS_PROM_PASSWORD "$work/pw-grafana" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || exit 1
  if [ "$rc" -eq 10 ] || ! obs_hub_has_user hk grafana; then obs_hub_set_user hk grafana "$work/pw-grafana"; echo "OK: hub user 'grafana' (datasource) set"; fi
  if ! obs_secret_key hk "$OBS_SECRET_GRAFANA_ADMIN" admin-password >/dev/null 2>&1; then
    mkdir -p "$work/admin"; printf 'admin' > "$work/admin/admin-user"; obs_random_password > "$work/admin/admin-password"
    obs_apply_secret hk "$OBS_SECRET_GRAFANA_ADMIN" "$work/admin"
    echo "OK: Grafana admin credential generated into Secret $OBS_SECRET_GRAFANA_ADMIN"
  fi
  rm -f "$work"/pw-*

  pkubectl -n "$OBS_NAMESPACE" create configmap "$OBS_GRAFANA_DASHBOARDS_CM" \
    --from-file=platform/observability/dashboards/ --dry-run=client -o yaml | pkubectl apply -f - >/dev/null
  echo "OK: dashboards ConfigMap $OBS_GRAFANA_DASHBOARDS_CM applied ($(ls platform/observability/dashboards/*.json | wc -l | tr -d ' ') dashboards)"

  obs_write_prom_config hub - "$work/prometheus.yml"
  obs_write_prom_values hub - "$work/prometheus.yml" "$work/values.yaml"
  upgrade_release "$OBS_RELEASE" "$OBS_PROM_CHART_TGZ" "prometheus-${OBS_PROM_CHART_VERSION}" \
    "$(shasum -a 256 "$work/values.yaml" | awk '{print $1}')" -f "$work/values.yaml"

  obs_write_grafana_values "$work/grafana.yaml"
  # Dashboards are mounted from the ConfigMap; their sha256 rolls the pod.
  dash_sha="$(cat platform/observability/dashboards/*.json | shasum -a 256 | awk '{print $1}')"
  printf 'podAnnotations:\n  platform.observability/dashboards-sha256: "%s"\n' "$dash_sha" > "$work/grafana-pod.yaml"
  upgrade_release "$OBS_GRAFANA_RELEASE" "$OBS_GRAFANA_CHART_TGZ" "grafana-${OBS_GRAFANA_CHART_VERSION}" \
    "$(cat "$work/grafana.yaml" "$work/grafana-pod.yaml" | shasum -a 256 | awk '{print $1}')" \
    -f "$work/grafana.yaml" -f "$work/grafana-pod.yaml"
else
  env="$LAB_CLUSTER"; user="spoke-${env}"
  rc=0; ensure_password pkubectl "$OBS_SECRET_REMOTE_WRITE" password "$work/pw" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || exit 1
  if [ "$rc" -eq 10 ] || ! obs_hub_has_user hk "$user"; then
    obs_hub_set_user hk "$user" "$work/pw"
    echo "OK: remote-write credential for '$user' generated on the spoke; its bcrypt hash added to the hub"
  else
    echo "OK: remote-write credential for '$user' already present on the spoke and the hub - kept"
  fi
  obs_hub_wait hk "$user" "$work/pw" accept
  rm -f "$work/pw"
  obs_write_prom_config spoke "$env" "$work/prometheus.yml"
  obs_write_prom_values spoke "$env" "$work/prometheus.yml" "$work/values.yaml"
  upgrade_release "$OBS_RELEASE" "$OBS_PROM_CHART_TGZ" "prometheus-${OBS_PROM_CHART_VERSION}" \
    "$(shasum -a 256 "$work/values.yaml" | awk '{print $1}')" -f "$work/values.yaml"
fi

echo "obs-install: OK ($role on '$PROJECT_CLUSTER_NAME')"
