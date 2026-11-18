#!/bin/sh
# Shared pins and helpers for lab/observability/*.sh (Phase 6.1b,
# ADR-0021). POSIX shell, sourced only, from the repository root, after
# scripts/lab/_lib.sh.
#
# Two roles, picked by LAB_CLUSTER:
#   hub              Prometheus (remote-write receiver, basic auth),
#                    Alertmanager, Grafana
#   dev | uat | prod Prometheus in agent mode + kube-state-metrics,
#                    remote-writing to the hub
# lab-lite has no role: it has no hub. Like ESO and metrics-server, the
# stack is installed by a script with admin rights, never by Argo CD.
# Everything lives in the namespace "monitoring", the one the workload
# chart opens its metrics port to (Phase 6.1a).

# --- pins (chart: version + sha256; images: multi-arch index digest) ---
# Chart versions were at least two weeks old when pinned (2026-11-18).
OBS_PROM_CHART_VERSION="29.40.3"
OBS_PROM_CHART_URL="https://github.com/prometheus-community/helm-charts/releases/download/prometheus-29.40.3/prometheus-29.40.3.tgz"
OBS_PROM_CHART_SHA256="901a2facca394c3c01d3e0e88b1d80a325a15c702d002de685e420d6909bd30f"
OBS_PROM_CHART_TGZ=".tools/charts/prometheus-${OBS_PROM_CHART_VERSION}.tgz"

OBS_GRAFANA_CHART_VERSION="14.3.1"
OBS_GRAFANA_CHART_URL="https://github.com/grafana-community/helm-charts/releases/download/grafana-14.3.1/grafana-14.3.1.tgz"
OBS_GRAFANA_CHART_SHA256="f49f848a9d6b4ab626610c0726b7e2a057f6c10e662a090bf7b30452d42f7bd5"
OBS_GRAFANA_CHART_TGZ=".tools/charts/grafana-${OBS_GRAFANA_CHART_VERSION}.tgz"

# Index digests resolved from each registry (manifest list / OCI index),
# never guessed. Charts that take no digest field get name:tag@digest in
# the tag, as for metrics-server.
OBS_PROM_IMAGE_REPOSITORY="quay.io/prometheus/prometheus"
OBS_PROM_IMAGE_TAG="v3.15.1"
OBS_PROM_IMAGE_DIGEST="sha256:fa3302279710be2f21a8301ec17a8b4f2301fd829bd113839b3b6b02b6f191a2"
OBS_AM_IMAGE_REPOSITORY="quay.io/prometheus/alertmanager"
OBS_AM_IMAGE_TAG="v0.34.2"
OBS_AM_IMAGE_DIGEST="sha256:39d8bb3966c694a124428a3a88fbcffd40bd069129ecd47c059f8a3f17c55f3b"
OBS_KSM_IMAGE_REGISTRY="registry.k8s.io"
OBS_KSM_IMAGE_REPOSITORY="kube-state-metrics/kube-state-metrics"
OBS_KSM_IMAGE_TAG="v2.20.0"
OBS_KSM_IMAGE_DIGEST="sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b"
OBS_GRAFANA_IMAGE_REGISTRY="docker.io"
OBS_GRAFANA_IMAGE_REPOSITORY="grafana/grafana"
OBS_GRAFANA_IMAGE_TAG="13.3.0-distroless"
OBS_GRAFANA_IMAGE_DIGEST="sha256:540b8afb775bf34aefce417e4329039daa5d44b6f2fbda6881397b1b247ca7df"

# --- names ---------------------------------------------------------------
OBS_NAMESPACE="monitoring"
OBS_RELEASE="obs"                      # prometheus chart, both roles
OBS_GRAFANA_RELEASE="obs-grafana"      # hub only
OBS_HUB_NODEPORT=30090
# The hub's node as seen from a spoke pod: the kind container name on the
# shared docker network, as Argo CD uses for the spokes' API servers.
OBS_HUB_WRITE_URL="http://eks-gitops-hub-control-plane:${OBS_HUB_NODEPORT}/api/v1/write"
OBS_HUB_QUERY_SVC="obs-prometheus-server"
OBS_GRAFANA_DS_UID="hub-prometheus"
# Secrets, generated at install, never in Git:
OBS_SECRET_WEB="obs-web-config"            # hub: web.yml + bcrypt hash per user
OBS_SECRET_SELF="obs-prometheus-self"      # hub: password of user "hub" (self-scrape)
OBS_SECRET_GRAFANA_ADMIN="obs-grafana-admin"   # hub: Grafana admin user/password
OBS_SECRET_GRAFANA_DS="obs-grafana-datasource" # hub: password of user "grafana"
OBS_SECRET_REMOTE_WRITE="obs-remote-write"     # spoke: its own remote-write password
# Dashboards: a ConfigMap the install script builds from
# platform/observability/dashboards/ (the chart's own "dashboards" value
# adds a curl init container; its extraObjects would template the JSON).
OBS_GRAFANA_DASHBOARDS_CM="obs-grafana-dashboards"

# Docker memory the install needs free, in MiB, per role. A floor for
# refusing early, not a promise. Measured 2026-11-18 (Docker view, hub +
# dev + uat): the hub node grew ~790 MiB (Prometheus 63Mi, Alertmanager
# 18Mi, Grafana 247Mi working set, plus node overhead); a spoke's agent
# and kube-state-metrics ~65Mi; the spoke floor is their memory limits.
OBS_HUB_MIB=900
OBS_SPOKE_MIB=350

HELM_BIN=".tools/bin/helm"
PROMTOOL_BIN=".tools/bin/promtool"
# shellcheck source=../lib/helm.sh
. scripts/lib/helm.sh

# obs_role - prints "hub" or "spoke" for LAB_CLUSTER; fails closed on
# lab-lite (no hub to write to) and anything else.
obs_role() {
  case "${LAB_CLUSTER:-lab-lite}" in
    hub) echo hub ;;
    dev|uat|prod) echo spoke ;;
    *) echo "FAIL: the observability stack runs only on lab-multicluster (LAB_CLUSTER=hub|dev|uat|prod), not on '${LAB_CLUSTER:-lab-lite}'" >&2; return 1 ;;
  esac
}

require_obs_charts() {
  for roc in "$OBS_PROM_CHART_TGZ:$OBS_PROM_CHART_SHA256" "$OBS_GRAFANA_CHART_TGZ:$OBS_GRAFANA_CHART_SHA256"; do
    roc_f="${roc%%:*}"; roc_sum="${roc##*:}"
    if [ ! -f "$roc_f" ]; then
      echo "FAIL: $roc_f not found - run 'make obs-chart-fetch' first" >&2; exit 1
    fi
    if [ "$(shasum -a 256 "$roc_f" | awk '{print $1}')" != "$roc_sum" ]; then
      echo "FAIL: $roc_f does not match the pinned checksum - run 'make obs-chart-fetch' again" >&2; exit 1
    fi
  done
}

# obs_write_prom_config <role> <env|-> <out> - the Prometheus config
# from platform/observability/, placeholders filled. No credential in it.
obs_write_prom_config() {
  case "$1" in
    hub) cp platform/observability/prometheus-hub.yml "$3" ;;
    spoke)
      sed -e "s|@CLUSTER@|spoke-$2|g" -e "s|@ENVIRONMENT@|$2|g" -e "s|@HUB_WRITE_URL@|${OBS_HUB_WRITE_URL}|g" \
        platform/observability/prometheus-spoke.yml > "$3"
      ;;
    *) echo "FAIL: unknown role '$1'" >&2; return 1 ;;
  esac
  if grep -q '@[A-Z_]*@' "$3"; then
    echo "FAIL: unfilled placeholder in the $1 Prometheus config" >&2; return 1
  fi
}

# _obs_indent <n> <file> - the file's lines, indented by n spaces.
_obs_indent() {
  awk -v n="$1" 'BEGIN { p = sprintf("%" n "s", "") } { print (length($0) ? p $0 : "") }' "$2"
}

# Container security context shared by every component.
_obs_container_sc() {
  cat <<EOF
$1allowPrivilegeEscalation: false
$1readOnlyRootFilesystem: true
$1capabilities:
$1  drop: ["ALL"]
EOF
}

# obs_write_prom_values <role> <env|-> <config-file> <out> - values for
# the prometheus chart. The config's sha256 rides in a pod annotation, so
# a changed config rolls the pod (no config-reloader sidecar: on the hub
# it would need the basic-auth password to call /-/reload).
obs_write_prom_values() {
  owv_role="$1"; owv_env="$2"; owv_cfg="$3"; owv_out="$4"
  owv_sha="$(shasum -a 256 "$owv_cfg" | awk '{print $1}')"
  {
    cat <<EOF
# Generated by scripts/observability/_lib.sh (role: ${owv_role}). The
# chart's own RBAC is off: the extraManifests below grant exactly what
# this role reads.
rbac:
  create: false
serviceAccounts:
  server:
    create: true
configmapReload:
  prometheus:
    enabled: false
alertmanager:
  enabled: $( [ "$owv_role" = hub ] && echo true || echo false )
prometheus-node-exporter:
  enabled: false
prometheus-pushgateway:
  enabled: false
kube-state-metrics:
  enabled: $( [ "$owv_role" = spoke ] && echo true || echo false )
server:
  image:
    repository: ${OBS_PROM_IMAGE_REPOSITORY}
    digest: "${OBS_PROM_IMAGE_DIGEST}"
  automountServiceAccountToken: $( [ "$owv_role" = spoke ] && echo true || echo false )
  configMapOverrideName: config
  persistentVolume:
    enabled: false
  emptyDir:
    sizeLimit: 1Gi
  podAnnotations:
    platform.observability/config-sha256: "${owv_sha}"
  securityContext:
    runAsUser: 65534
    runAsGroup: 65534
    runAsNonRoot: true
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
$(_obs_container_sc "    ")
EOF
    if [ "$owv_role" = spoke ]; then
      cat <<EOF
  defaultFlagsOverride:
    - --agent
    - --config.file=/etc/config/prometheus.yml
    - --storage.agent.path=/data
  extraSecretMounts:
    - name: remote-write
      mountPath: /etc/remote-write
      secretName: ${OBS_SECRET_REMOTE_WRITE}
      readOnly: true
  resources:
    requests:
      cpu: 25m
      memory: 96Mi
    limits:
      memory: 256Mi
kube-state-metrics:
  enabled: true
  image:
    registry: ${OBS_KSM_IMAGE_REGISTRY}
    repository: ${OBS_KSM_IMAGE_REPOSITORY}
    tag: ${OBS_KSM_IMAGE_TAG}
    sha: "${OBS_KSM_IMAGE_DIGEST}"
  namespaces: ${owv_env}
  rbac:
    useClusterRole: false
  collectors:
    - deployments
    - pods
    - horizontalpodautoscalers
  securityContext:
    enabled: true
    runAsUser: 65534
    runAsGroup: 65534
    runAsNonRoot: true
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 96Mi
EOF
    else
      cat <<EOF
  # LAB-ONLY plain HTTP; spokes reach this NodePort over the kind network.
  service:
    type: NodePort
    nodePort: ${OBS_HUB_NODEPORT}
  # Every endpoint needs basic auth, so the kubelet probes check the TCP
  # port only (an HTTP probe would need the password in the pod spec).
  tcpSocketProbeEnabled: true
  defaultFlagsOverride:
    - --config.file=/etc/config/prometheus.yml
    - --storage.tsdb.path=/data
    - --storage.tsdb.retention.time=7d
    - --web.enable-remote-write-receiver
    - --web.config.file=/etc/web/web.yml
  extraSecretMounts:
    - name: web-config
      mountPath: /etc/web
      secretName: ${OBS_SECRET_WEB}
      readOnly: true
    - name: self
      mountPath: /etc/prometheus-self
      secretName: ${OBS_SECRET_SELF}
      readOnly: true
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
    limits:
      memory: 768Mi
alertmanager:
  enabled: true
  automountServiceAccountToken: false
  image:
    repository: ${OBS_AM_IMAGE_REPOSITORY}
    tag: "${OBS_AM_IMAGE_TAG}@${OBS_AM_IMAGE_DIGEST}"
  persistence:
    enabled: false
  configmapReload:
    enabled: false
  # No external receiver in the lab (no webhook URL or token to keep);
  # alerts are read from the Alertmanager API.
  config:
    global: {}
    route:
      receiver: "null"
      group_by: [alertname, cluster]
    receivers:
      - name: "null"
  podSecurityContext:
    runAsUser: 65534
    runAsGroup: 65534
    runAsNonRoot: true
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  securityContext:
$(_obs_container_sc "    ")
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 96Mi
EOF
    fi
    echo "extraManifests:"
    # The Prometheus config, as the ConfigMap the chart mounts.
    cat <<EOF
  - |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ${OBS_RELEASE}-config
      namespace: ${OBS_NAMESPACE}
    data:
      prometheus.yml: |
EOF
    _obs_indent 8 "$owv_cfg"
    if [ "$owv_role" = spoke ]; then
      cat <<EOF
  # Kubelet cAdvisor and node discovery: nodes and nodes/metrics, read only.
  - |
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: obs-prometheus-agent
    rules:
      - apiGroups: [""]
        resources: [nodes, nodes/metrics]
        verbs: [get, list, watch]
  - |
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: obs-prometheus-agent
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: obs-prometheus-agent
    subjects:
      - kind: ServiceAccount
        name: ${OBS_RELEASE}-prometheus-server
        namespace: ${OBS_NAMESPACE}
  # Pod discovery for the workload job: the environment namespace only.
  - |
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: obs-prometheus-agent
      namespace: ${owv_env}
    rules:
      - apiGroups: [""]
        resources: [pods]
        verbs: [get, list, watch]
  - |
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: obs-prometheus-agent
      namespace: ${owv_env}
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: obs-prometheus-agent
    subjects:
      - kind: ServiceAccount
        name: ${OBS_RELEASE}-prometheus-server
        namespace: ${OBS_NAMESPACE}
  # Ingress: nothing reaches the agent; kube-state-metrics only from it.
  - |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: obs-default-deny-ingress
      namespace: ${OBS_NAMESPACE}
    spec:
      podSelector: {}
      policyTypes: [Ingress]
  - |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: obs-kube-state-metrics
      namespace: ${OBS_NAMESPACE}
    spec:
      podSelector:
        matchLabels:
          app.kubernetes.io/name: kube-state-metrics
      policyTypes: [Ingress]
      ingress:
        - from:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/name: prometheus
                  app.kubernetes.io/component: server
          ports:
            - port: 8080
              protocol: TCP
EOF
    else
      cat <<EOF
  # Ingress: the Prometheus port from anywhere (spokes arrive through the
  # NodePort; basic auth gates every request), Alertmanager only from
  # Prometheus, Grafana only from Prometheus (its /metrics). People reach
  # Grafana and Prometheus by port-forward.
  - |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: obs-default-deny-ingress
      namespace: ${OBS_NAMESPACE}
    spec:
      podSelector: {}
      policyTypes: [Ingress]
  - |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: obs-prometheus-server
      namespace: ${OBS_NAMESPACE}
    spec:
      podSelector:
        matchLabels:
          app.kubernetes.io/name: prometheus
          app.kubernetes.io/component: server
      policyTypes: [Ingress]
      ingress:
        - ports:
            - port: 9090
              protocol: TCP
  - |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: obs-from-prometheus
      namespace: ${OBS_NAMESPACE}
    spec:
      podSelector:
        matchExpressions:
          - key: app.kubernetes.io/name
            operator: In
            values: [alertmanager, grafana]
      policyTypes: [Ingress]
      ingress:
        - from:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/name: prometheus
                  app.kubernetes.io/component: server
          ports:
            - port: 9093
              protocol: TCP
            - port: 3000
              protocol: TCP
EOF
    fi
  } > "$owv_out"
}

# obs_write_grafana_values <out> - values for the Grafana
# chart (hub only). The datasource password comes from the environment
# (Secret ${OBS_SECRET_GRAFANA_DS}); the dashboards from the ConfigMap
# ${OBS_GRAFANA_DASHBOARDS_CM}.
obs_write_grafana_values() {
  cat > "$1" <<EOF
# Generated by scripts/observability/_lib.sh.
image:
  registry: ${OBS_GRAFANA_IMAGE_REGISTRY}
  repository: ${OBS_GRAFANA_IMAGE_REPOSITORY}
  tag: "${OBS_GRAFANA_IMAGE_TAG}"
  # this chart prepends "sha256:" itself
  sha: "${OBS_GRAFANA_IMAGE_DIGEST#sha256:}"
rbac:
  create: false
  namespaced: true
serviceAccount:
  create: true
  automountServiceAccountToken: false
automountServiceAccountToken: false
testFramework:
  enabled: false
initChownData:
  enabled: false
persistence:
  enabled: false
admin:
  existingSecret: ${OBS_SECRET_GRAFANA_ADMIN}
  userKey: admin-user
  passwordKey: admin-password
envFromSecret: ${OBS_SECRET_GRAFANA_DS}
securityContext:
  runAsUser: 472
  runAsGroup: 472
  runAsNonRoot: true
  fsGroup: 472
  seccompProfile:
    type: RuntimeDefault
containerSecurityContext:
$(_obs_container_sc "  ")
# Measured 247Mi working set right after start (Phase 6.1b).
resources:
  requests:
    cpu: 25m
    memory: 256Mi
  limits:
    memory: 512Mi
grafana.ini:
  analytics:
    reporting_enabled: false
    check_for_updates: false
    check_for_plugin_updates: false
  auth.anonymous:
    enabled: false
  users:
    allow_sign_up: false
  news:
    news_feed_enabled: false
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus (hub)
        uid: ${OBS_GRAFANA_DS_UID}
        type: prometheus
        access: proxy
        url: http://${OBS_HUB_QUERY_SVC}.${OBS_NAMESPACE}.svc
        isDefault: true
        editable: false
        basicAuth: true
        basicAuthUser: grafana
        secureJsonData:
          basicAuthPassword: \$__env{OBS_PROM_PASSWORD}
dashboardsConfigMaps:
  platform: ${OBS_GRAFANA_DASHBOARDS_CM}
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: platform
        folder: Platform
        type: file
        disableDeletion: true
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards/platform
EOF
}

# --- credentials (install time only; values never printed) ----------------
# Every helper below takes a kubectl wrapper name as $1, so the same code
# writes the hub's Secrets from the hub's own install and from a spoke's.

require_htpasswd() {
  command -v htpasswd >/dev/null 2>&1 || { echo "FAIL: htpasswd not found (bcrypt hashes for the hub's web config; macOS ships it, Debian/Ubuntu: apache2-utils)" >&2; exit 1; }
}

# obs_random_password - 32 alphanumeric characters from /dev/urandom.
obs_random_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

# obs_secret_key <kubectl-fn> <secret> <key> - the decoded value of one
# key, or nothing (exit 1) when the Secret or key is absent.
obs_secret_key() {
  osk_v="$("$1" -n "$OBS_NAMESPACE" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null)" || return 1
  [ -n "$osk_v" ] || return 1
  printf '%s' "$osk_v" | base64 -d
}

# obs_apply_secret <kubectl-fn> <secret> <dir> - (re)writes a Secret from
# the files in <dir> (one key per file), without the values ever reaching
# argv or stdout.
obs_apply_secret() {
  "$1" -n "$OBS_NAMESPACE" create secret generic "$2" --from-file="$3" --dry-run=client -o yaml \
    | "$1" apply -f - >/dev/null
}

# obs_ensure_namespace <kubectl-fn> - the monitoring namespace, Pod
# Security "restricted" enforced.
obs_ensure_namespace() {
  "$1" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${OBS_NAMESPACE}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.36
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
YAML
}

# obs_hub_set_user <hub-kubectl-fn> <user> <password-file> - adds or
# replaces <user>'s bcrypt hash in the hub's web config and rewrites
# web.yml from the full list. Prometheus re-reads web.yml on each request,
# so the change applies once the kubelet refreshes the mounted Secret.
obs_hub_set_user() {
  ohs_dir="$(mktemp -d)"
  obs_secret_key "$1" "$OBS_SECRET_WEB" users > "$ohs_dir/users.old" 2>/dev/null || : > "$ohs_dir/users.old"
  ohs_hash="$(htpasswd -niBC 10 "$2" < "$3" | cut -d: -f2-)"
  [ -n "$ohs_hash" ] || { rm -rf "$ohs_dir"; echo "FAIL: htpasswd produced no hash for '$2'" >&2; return 1; }
  awk -v u="$2" '$1 != u' "$ohs_dir/users.old" > "$ohs_dir/users.new"
  printf '%s %s\n' "$2" "$ohs_hash" >> "$ohs_dir/users.new"
  _obs_hub_write_web "$1" "$ohs_dir" "$ohs_dir/users.new"
}

# obs_hub_remove_user <hub-kubectl-fn> <user> - removes <user> (its spoke
# can no longer write); a no-op when absent.
obs_hub_remove_user() {
  ohr_dir="$(mktemp -d)"
  if ! obs_secret_key "$1" "$OBS_SECRET_WEB" users > "$ohr_dir/users.old" 2>/dev/null; then rm -rf "$ohr_dir"; return 0; fi
  if ! awk -v u="$2" '$1 == u { f = 1 } END { exit !f }' "$ohr_dir/users.old"; then rm -rf "$ohr_dir"; return 0; fi
  awk -v u="$2" '$1 != u' "$ohr_dir/users.old" > "$ohr_dir/users.new"
  _obs_hub_write_web "$1" "$ohr_dir" "$ohr_dir/users.new"
}

# obs_hub_has_user <hub-kubectl-fn> <user>
obs_hub_has_user() {
  obs_secret_key "$1" "$OBS_SECRET_WEB" users 2>/dev/null | awk -v u="$2" '$1 == u { f = 1 } END { exit !f }'
}

_obs_hub_write_web() {
  mkdir -p "$2/secret"
  sort "$3" > "$2/secret/users"
  {
    echo "# Generated by lab/observability (Phase 6.1b): one bcrypt hash per user."
    echo "basic_auth_users:"
    awk '{ printf "  %s: \"%s\"\n", $1, $2 }' "$2/secret/users"
  } > "$2/secret/web.yml"
  obs_apply_secret "$1" "$OBS_SECRET_WEB" "$2/secret"
  rm -rf "$2"
}

# obs_hub_wait <hub-kubectl-fn> <user> <password-file> <accept|refuse> [timeout-s]
# - waits until the hub's Prometheus accepts (or refuses) <user>'s
# credential. The kubelet refreshes the mounted web config about a minute
# after a change, so a new user is not accepted, and a removed one not
# refused, right away. Probes with a remote write whose body is not
# valid: 401 means refused; 400 means authenticated (nothing is written).
# Without the accept wait, an agent started at once has its first samples
# refused with 401, which Prometheus does not retry.
obs_hub_wait() {
  ow_kc="$1"; ow_user="$2"; ow_pw="$3"; ow_want="$4"; ow_timeout="${5:-180}"
  ow_dir="$(mktemp -d)"
  ow_port="$(awk 'BEGIN { srand(); print 20000 + int(rand() * 20000) }')"
  "$ow_kc" -n "$OBS_NAMESPACE" port-forward "svc/${OBS_HUB_QUERY_SVC}" "${ow_port}:80" >/dev/null 2>&1 &
  ow_pf=$!
  { printf 'machine 127.0.0.1 login %s password ' "$ow_user"; cat "$ow_pw"; printf '\n'; } > "$ow_dir/netrc"
  chmod 600 "$ow_dir/netrc"
  ow_start="$(date +%s)"; ow_code=""; ow_done=1
  while [ $(( $(date +%s) - ow_start )) -lt "$ow_timeout" ]; do
    ow_code="$(curl -s -o /dev/null -w '%{http_code}' --netrc-file "$ow_dir/netrc" -X POST \
      -H 'Content-Type: application/x-protobuf' --data-binary 'x' "http://127.0.0.1:${ow_port}/api/v1/write" 2>/dev/null || true)"
    case "$ow_want:$ow_code" in
      accept:2??|accept:400|accept:415|refuse:401) ow_done=0; break ;;
    esac
    sleep 5
  done
  kill "$ow_pf" 2>/dev/null || true
  wait "$ow_pf" 2>/dev/null || true
  rm -rf "$ow_dir"
  if [ "$ow_done" -eq 0 ]; then
    echo "OK: the hub ${ow_want}s '$ow_user' (probe answered $ow_code after $(( $(date +%s) - ow_start ))s)"
    return 0
  fi
  echo "FAIL: the hub does not ${ow_want} '$ow_user' after ${ow_timeout}s (last answer: ${ow_code:-none})" >&2
  return 1
}
