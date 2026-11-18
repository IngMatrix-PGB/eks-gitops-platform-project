#!/bin/sh
# Fully offline render of the observability stack for both roles (Phase
# 6.1b, ADR-0021), plus proof of its shape. Never touches a cluster.
# Backs `make obs-render`. Needs the pinned charts (`make obs-chart-fetch`),
# so, like metrics-server-render, it is not part of `make validate`;
# check-observability (offline, in validate) covers the configs and
# dashboards themselves.
#
# Proves, per role:
#   - the exact set of rendered objects;
#   - every image is one of the pinned digests;
#   - no Secret is rendered (credentials are created by the install script
#     only, never carried in a release);
#   - no RBAC wildcard; the spoke reads nodes cluster-wide and pods only in
#     its environment namespace; the hub has no RBAC at all;
#   - every container: non-root, read-only root filesystem, no privilege
#     escalation, all capabilities dropped; RuntimeDefault seccomp; no host
#     network;
#   - NetworkPolicy: default-deny ingress in the namespace;
#   - spoke: agent mode; remote-write password from its Secret; no NodePort;
#   - hub: remote-write receiver and web config (basic auth) on; TCP probes;
#     NodePort 30090 on the Prometheus Service only; Grafana's datasource is
#     the provisioned UID and anonymous access is off.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/observability/_lib.sh
require_helm
require_obs_charts
# eso_check_no_rbac_wildcards: the structural RBAC scanner ESO and
# metrics-server use.
# shellcheck source=../../scripts/eso/_lib.sh
LAB_CLUSTER=lab-lite . scripts/eso/_lib.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# $1=label $2=render file $3=expected "kind xN" list
check_kinds() {
  ck_got="$(grep -E '^kind: ' "$2" | sort | uniq -c | awk '{print $3"x"$1}' | tr '\n' ' ')"
  if [ "$ck_got" = "$3" ]; then ok "$1: exact object set: $ck_got"; else bad "$1: object set '$ck_got', expected '$3'"; fi
}

# $1=label $2=render file $3...=allowed image references
check_images() {
  ci_label="$1"; ci_file="$2"; shift 2
  sed -n 's/^[[:space:]]*image: //p' "$ci_file" | tr -d '"' | sort -u > "$work/images"
  ci_bad=0
  while IFS= read -r ci_img; do
    ci_ok=0
    for ci_allowed in "$@"; do [ "$ci_img" = "$ci_allowed" ] && ci_ok=1; done
    [ "$ci_ok" -eq 1 ] || { bad "$ci_label: unpinned or unexpected image $ci_img"; ci_bad=1; }
  done < "$work/images"
  if [ "$ci_bad" -eq 0 ]; then ok "$ci_label: every image is a pinned digest ($(wc -l < "$work/images" | tr -d ' '))"; fi
}

# $1=label $2=render file - per-container security fields counted against
# the number of containers.
check_security() {
  cs_n="$(grep -cE '^[[:space:]]+image: ' "$2" || true)"
  for cs_needle in 'allowPrivilegeEscalation: false' 'readOnlyRootFilesystem: true'; do
    cs_have="$(grep -cF -- "$cs_needle" "$2" || true)"
    [ "$cs_have" -ge "$cs_n" ] || bad "$1: '$cs_needle' on $cs_have of $cs_n containers"
  done
  cs_drop="$(grep -cE -- '^[[:space:]]+- (ALL|"ALL")$|drop: \["ALL"\]' "$2" || true)"
  [ "$cs_drop" -ge "$cs_n" ] || bad "$1: capabilities drop ALL on $cs_drop of $cs_n containers"
  cs_pods="$(grep -cE '^kind: (Deployment|StatefulSet)$' "$2" || true)"
  cs_nonroot="$(grep -cF 'runAsNonRoot: true' "$2" || true)"
  cs_seccomp="$(grep -cF 'type: RuntimeDefault' "$2" || true)"
  [ "$cs_nonroot" -ge "$cs_pods" ] || bad "$1: runAsNonRoot on $cs_nonroot of $cs_pods pods"
  [ "$cs_seccomp" -ge "$cs_pods" ] || bad "$1: RuntimeDefault seccomp on $cs_seccomp of $cs_pods pods"
  if grep -q 'hostNetwork: true' "$2"; then bad "$1: hostNetwork: true"; fi
  if grep -qE '^kind: Secret$' "$2"; then bad "$1: renders a Secret (credentials must come from the install script)"; fi
  cs_hits="$(eso_check_no_rbac_wildcards "$2" || true)"
  [ -z "$cs_hits" ] || bad "$1: RBAC wildcard: $cs_hits"
  if [ "$fail" -eq 0 ]; then ok "$1: $cs_n containers restricted (non-root, read-only, no escalation, drop ALL, RuntimeDefault); no host network, no Secret, no RBAC wildcard"; fi
}

prom_img="${OBS_PROM_IMAGE_REPOSITORY}@${OBS_PROM_IMAGE_DIGEST}"
ksm_img="${OBS_KSM_IMAGE_REGISTRY}/${OBS_KSM_IMAGE_REPOSITORY}:${OBS_KSM_IMAGE_TAG}@${OBS_KSM_IMAGE_DIGEST}"
am_img="${OBS_AM_IMAGE_REPOSITORY}:${OBS_AM_IMAGE_TAG}@${OBS_AM_IMAGE_DIGEST}"
graf_img="${OBS_GRAFANA_IMAGE_REGISTRY}/${OBS_GRAFANA_IMAGE_REPOSITORY}:${OBS_GRAFANA_IMAGE_TAG}@${OBS_GRAFANA_IMAGE_DIGEST}"

# --- spoke (every environment renders the same shape) -----------------------
for env in dev uat prod; do
  obs_write_prom_config spoke "$env" "$work/cfg-$env.yml"
  obs_write_prom_values spoke "$env" "$work/cfg-$env.yml" "$work/values-$env.yaml"
  "$HELM_BIN" lint "$OBS_PROM_CHART_TGZ" -n "$OBS_NAMESPACE" -f "$work/values-$env.yaml" >/dev/null || bad "spoke-$env: helm lint failed"
  "$HELM_BIN" template "$OBS_RELEASE" "$OBS_PROM_CHART_TGZ" -n "$OBS_NAMESPACE" -f "$work/values-$env.yaml" > "$work/spoke-$env.yaml"
done
s="$work/spoke-dev.yaml"
check_kinds "spoke" "$s" "ClusterRolex1 ClusterRoleBindingx1 ConfigMapx1 Deploymentx2 NetworkPolicyx2 Rolex2 RoleBindingx2 Servicex2 ServiceAccountx2 "
check_images "spoke" "$s" "$prom_img" "$ksm_img"
check_security "spoke" "$s"
grep -qF -- '- --agent' "$s" && ok "spoke: Prometheus runs in agent mode" || bad "spoke: --agent missing"
grep -qF 'secretName: obs-remote-write' "$s" && grep -qF 'password_file: /etc/remote-write/password' "$s" \
  && ok "spoke: remote-write password read from the Secret obs-remote-write" || bad "spoke: remote-write credential wiring missing"
grep -q 'NodePort' "$s" && bad "spoke: renders a NodePort" || ok "spoke: no NodePort"
# RBAC: cluster-wide only nodes and nodes/metrics; pods only in the env namespace.
cr="$(awk '/^kind: ClusterRole$/{f=1} f&&/^---/{f=0} f' "$s" | grep -E 'resources:' | tr -d ' ')"
[ "$cr" = "resources:[nodes,nodes/metrics]" ] && ok "spoke: cluster-wide RBAC is nodes and nodes/metrics only" || bad "spoke: unexpected ClusterRole resources: $cr"
for env in dev uat prod; do
  grep -qE "^  namespace: ${env}$" "$work/spoke-$env.yaml" && grep -qF "names: [\"${env}\"]" "$work/spoke-$env.yaml" \
    && grep -qF "cluster: \"spoke-${env}\"" "$work/spoke-$env.yaml" && grep -qF -- "- --namespaces=${env}" "$work/spoke-$env.yaml" \
    || bad "spoke-$env: pods Role, pod discovery, kube-state-metrics or cluster label not scoped to '$env'"
done
if [ "$fail" -eq 0 ]; then ok "spoke: dev, uat and prod each scoped to their own namespace and labeled cluster=spoke-<env>"; fi

# --- hub ----------------------------------------------------------------------
obs_write_prom_config hub - "$work/cfg-hub.yml"
obs_write_prom_values hub - "$work/cfg-hub.yml" "$work/values-hub.yaml"
"$HELM_BIN" lint "$OBS_PROM_CHART_TGZ" -n "$OBS_NAMESPACE" -f "$work/values-hub.yaml" >/dev/null || bad "hub: helm lint failed"
"$HELM_BIN" template "$OBS_RELEASE" "$OBS_PROM_CHART_TGZ" -n "$OBS_NAMESPACE" -f "$work/values-hub.yaml" > "$work/hub.yaml"
obs_write_grafana_values "$work/values-grafana.yaml"
"$HELM_BIN" lint "$OBS_GRAFANA_CHART_TGZ" -n "$OBS_NAMESPACE" -f "$work/values-grafana.yaml" >/dev/null || bad "grafana: helm lint failed"
"$HELM_BIN" template "$OBS_GRAFANA_RELEASE" "$OBS_GRAFANA_CHART_TGZ" -n "$OBS_NAMESPACE" -f "$work/values-grafana.yaml" > "$work/grafana.yaml"
h="$work/hub.yaml"; g="$work/grafana.yaml"
check_kinds "hub" "$h" "ConfigMapx2 Deploymentx1 NetworkPolicyx3 Servicex3 ServiceAccountx2 StatefulSetx1 "
check_kinds "grafana" "$g" "ConfigMapx1 Deploymentx1 Servicex1 ServiceAccountx1 "
check_images "hub" "$h" "$prom_img" "$am_img"
check_images "grafana" "$g" "$graf_img"
check_security "hub" "$h"
check_security "grafana" "$g"
for flag in '--web.enable-remote-write-receiver' '--web.config.file=/etc/web/web.yml'; do
  grep -qF -- "- $flag" "$h" || bad "hub: $flag missing"
done
grep -qF 'secretName: obs-web-config' "$h" || bad "hub: web config Secret not mounted"
awk '/^kind: Deployment$/{f=1} f&&/^---/{f=0} f' "$h" > "$work/hub-server.yaml"
[ "$(grep -c 'tcpSocket:' "$work/hub-server.yaml")" -eq 2 ] && ! grep -q 'httpGet:' "$work/hub-server.yaml" \
  && ok "hub: remote-write receiver and basic auth on; kubelet probes are TCP (no credential in the pod spec)" || bad "hub: probes are not TCP-only"
[ "$(grep -c 'nodePort:' "$h")" -eq 1 ] && grep -qE "nodePort: ${OBS_HUB_NODEPORT}$" "$h" \
  && ok "hub: one NodePort (${OBS_HUB_NODEPORT}), on the Prometheus Service" || bad "hub: unexpected NodePort set"
grep -qE '^kind: (ClusterRole|Role|ClusterRoleBinding|RoleBinding)$' "$h" "$g" && bad "hub: renders RBAC (it reads nothing from the API)" || ok "hub: no RBAC objects"
[ "$(grep -c 'automountServiceAccountToken: false' "$h")" -ge 2 ] && grep -q 'automountServiceAccountToken: false' "$g" \
  && ok "hub: no service account token mounted" || bad "hub: a pod mounts its service account token"
grep -qF "uid: ${OBS_GRAFANA_DS_UID}" "$g" && grep -qF 'basicAuthPassword: $__env{OBS_PROM_PASSWORD}' "$g" \
  && ok "grafana: one provisioned datasource (${OBS_GRAFANA_DS_UID}), password from the environment" || bad "grafana: datasource provisioning wrong"
awk '/^[[:space:]]*\[auth.anonymous\]/{f=1;next} /^[[:space:]]*\[/{f=0} f' "$g" | grep -qE '^[[:space:]]*enabled = false$' && ok "grafana: anonymous access off" || bad "grafana: anonymous access not off"
for ns_render in "$s" "$h"; do
  grep -q 'name: obs-default-deny-ingress' "$ns_render" || bad "default-deny ingress NetworkPolicy missing"
done

if [ "$fail" -ne 0 ]; then echo "obs-render: FAILED"; exit 1; fi
echo "obs-render: OK"
