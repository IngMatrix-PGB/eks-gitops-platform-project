#!/bin/sh
# Idempotent removal of the observability stack from one lab-multicluster
# member (Phase 6.1b). Backs `make obs-uninstall LAB_CLUSTER=hub|dev|uat|prod`.
#
#   spoke  uninstalls releases obs-logs (namespace logging) and obs,
#          deletes their Secrets and the logging NetworkPolicy and, when the
#          hub is up, removes user spoke-<env> from the hub's web config and
#          waits until the hub's Prometheus and Loki gateway both refuse that
#          credential (401), so the removed spoke can no longer write.
#   hub    uninstalls obs-grafana, obs-loki and obs, deletes the dashboards ConfigMap
#          and the Secrets this stack created. Spokes still installed then
#          fail their remote writes until they are removed too.
# Deletes only objects this stack created, by name; the namespace stays.
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

uninstall_release() { # $1=release [$2=namespace]
  if phelm status "$1" -n "${2:-$OBS_NAMESPACE}" >/dev/null 2>&1; then
    phelm uninstall "$1" -n "${2:-$OBS_NAMESPACE}" --wait --timeout 5m >/dev/null
    echo "OK: release '$1' uninstalled from '$PROJECT_CLUSTER_NAME'"
  else
    echo "OK: release '$1' already absent on '$PROJECT_CLUSTER_NAME' - no-op"
  fi
}

delete_named() { # $1=kind $2=name [$3=namespace]
  pkubectl -n "${3:-$OBS_NAMESPACE}" delete "$1" "$2" --ignore-not-found >/dev/null
  echo "OK: $1/$2 absent"
}

if [ "$role" = spoke ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT INT TERM
  umask 077
  # Keep the password (in a mktemp file) to prove the hub refuses it.
  have_pw=0
  obs_secret_key pkubectl "$OBS_SECRET_REMOTE_WRITE" password > "$work/pw" 2>/dev/null && have_pw=1
  uninstall_release "$OBS_LOGS_RELEASE" "$OBS_LOGS_NAMESPACE"
  delete_named secret "$OBS_SECRET_LOGS_PUSH" "$OBS_LOGS_NAMESPACE"
  delete_named networkpolicy obs-default-deny-ingress "$OBS_LOGS_NAMESPACE"
  uninstall_release "$OBS_RELEASE"
  delete_named secret "$OBS_SECRET_REMOTE_WRITE"
  hk() { ckubectl hub "$@"; }
  if lab_mc_identity hub; then
    obs_hub_remove_user hk "spoke-${LAB_CLUSTER}"
    echo "OK: user 'spoke-${LAB_CLUSTER}' absent from the hub's web config"
    if [ "$have_pw" -eq 1 ]; then
      obs_hub_wait hk "spoke-${LAB_CLUSTER}" "$work/pw" refuse 180 prometheus
      obs_hub_wait hk "spoke-${LAB_CLUSTER}" "$work/pw" refuse 180 loki
    fi
  else
    echo "obs-uninstall: hub not up ($LAB_MC_IDENTITY_CASE) - nothing to remove there"
  fi
else
  uninstall_release "$OBS_GRAFANA_RELEASE"
  uninstall_release "$OBS_LOKI_RELEASE"
  uninstall_release "$OBS_RELEASE"
  delete_named configmap "$OBS_GRAFANA_DASHBOARDS_CM"
  for s in "$OBS_SECRET_WEB" "$OBS_SECRET_SELF" "$OBS_SECRET_GRAFANA_ADMIN" "$OBS_SECRET_GRAFANA_DS"; do
    delete_named secret "$s"
  done
fi
echo "obs-uninstall: OK ($role on '$PROJECT_CLUSTER_NAME')"
