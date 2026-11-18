#!/bin/sh
# Shared pins and helpers for lab/backup/*.sh (Phase 6.2a, ADR-0022).
# POSIX shell, sourced only, from the repository root, after
# scripts/lab/_lib.sh.
#
# Velero backs up only the state that is not in Git (Secrets and
# ConfigMaps of the platform namespaces; PersistentVolumeClaims from 6.3)
# to an S3-compatible store. In the lab the store is Versity S3 Gateway
# (versitygw, Apache-2.0), one container on the kind docker network with
# only its S3 port exposed; its data, metadata and IAM file are
# bind-mounted under .local/backups/ so they outlive every cluster. One
# bucket and one credential per cluster; a cluster's key can only reach
# its own bucket (bucket owner), and the key survives the cluster, so a
# rebuilt cluster can restore its backups.

# --- pins (at least two weeks old when pinned, 2026-11-18) ----------------
BK_VELERO_CHART_VERSION="12.2.3"
BK_VELERO_CHART_URL="https://github.com/vmware-tanzu/helm-charts/releases/download/velero-12.2.3/velero-12.2.3.tgz"
BK_VELERO_CHART_SHA256="81741f2ac7e6013663b5482e5cc6e2258e9f393d2d0eb982b1a278e52bfcd08b"
BK_VELERO_CHART_TGZ=".tools/charts/velero-${BK_VELERO_CHART_VERSION}.tgz"
BK_VELERO_IMAGE_REPOSITORY="docker.io/velero/velero"
BK_VELERO_IMAGE_TAG="v1.18.2"
BK_VELERO_IMAGE_DIGEST="sha256:37396519f399536e5f01427d723565ae69294ec3fb5625cf1c87c09eaa9de16b"
# v1.14.x is the plugin line for Velero v1.18.x (plugin compatibility table).
BK_AWS_PLUGIN_IMAGE="docker.io/velero/velero-plugin-for-aws:v1.14.4@sha256:c85a7fa803569e3128c33e4f5766f84ab156c8d171c9f1dd2715581d45ce98fa"
BK_STORE_IMAGE="docker.io/versity/versitygw:v1.10.0@sha256:89cad13cc981986ee284cbafea4613f9533ce6fd5f37a2c96c4c4fb8adb3a316"

# --- names -----------------------------------------------------------------
BK_NAMESPACE="velero"
BK_RELEASE="velero"
BK_STORE_CONTAINER="eks-gitops-backup-store"
BK_STORE_NETWORK="kind"
BK_STORE_PORT=7070
BK_STORE_URL="http://${BK_STORE_CONTAINER}:${BK_STORE_PORT}"
BK_STORE_DIR=".local/backups"
BK_STORE_IAM="${BK_STORE_DIR}/iam/users.json"
BK_STORE_ROOT_ENV="${BK_STORE_DIR}/config/root.env"
BK_STORE_ADMIN_ENV="${BK_STORE_DIR}/config/admin.env"
BK_SECRET="velero-store-credentials"
BK_REGION="us-east-1"
# Docker memory a first install needs free, in MiB (its memory limit).
BK_MIB=256

HELM_BIN=".tools/bin/helm"
# shellcheck source=../lib/helm.sh
. scripts/lib/helm.sh

bk_bucket() { printf 'velero-%s\n' "$1"; }

# bk_role - "hub" or "spoke" for LAB_CLUSTER; fails closed elsewhere.
bk_role() {
  case "${LAB_CLUSTER:-lab-lite}" in
    hub) echo hub ;;
    dev|uat|prod) echo spoke ;;
    *) echo "FAIL: backups run only on lab-multicluster (LAB_CLUSTER=hub|dev|uat|prod), not on '${LAB_CLUSTER:-lab-lite}'" >&2; return 1 ;;
  esac
}

# bk_namespaces <cluster> - the namespaces whose out-of-Git state is
# backed up (D4): the hub's Argo CD and monitoring Secrets; a spoke's ESO
# source, its monitoring and logging credentials.
bk_namespaces() {
  case "$1" in
    hub) echo "argocd monitoring" ;;
    dev|uat|prod) echo "eso-source-$1 monitoring logging" ;;
    *) return 1 ;;
  esac
}

require_bk_chart() {
  [ -f "$BK_VELERO_CHART_TGZ" ] || { echo "FAIL: $BK_VELERO_CHART_TGZ not found - run 'make backup-chart-fetch' first" >&2; exit 1; }
  [ "$(shasum -a 256 "$BK_VELERO_CHART_TGZ" | awk '{print $1}')" = "$BK_VELERO_CHART_SHA256" ] \
    || { echo "FAIL: $BK_VELERO_CHART_TGZ does not match the pinned checksum - run 'make backup-chart-fetch' again" >&2; exit 1; }
}

bk_store_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$BK_STORE_CONTAINER" 2>/dev/null)" = "true" ]
}

# bk_store_admin <args...> - the gateway's admin CLI inside the store,
# root credentials from a mode-600 env file (never on argv).
bk_store_admin() {
  docker exec --env-file "$BK_STORE_ADMIN_ENV" "$BK_STORE_CONTAINER" versitygw admin "$@"
}

# bk_store_ensure_cluster <cluster> - an S3 user velero-<cluster> (role
# "user", kept if present) and its bucket velero-<cluster>, owned by it.
# The gateway reads its IAM file on every request (cache disabled), so no
# restart is needed and no secret passes through argv.
bk_store_ensure_cluster() {
  bec_user="velero-$1"; bec_bucket="$(bk_bucket "$1")"
  python3 -I - "$BK_STORE_IAM" "$bec_user" <<'PY' || return 1
import json, os, secrets, string, sys
path, user = sys.argv[1], sys.argv[2]
data = {"accessAccounts": {}}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
acc = data.setdefault("accessAccounts", {})
if user not in acc:
    alphabet = string.ascii_letters + string.digits
    acc[user] = {"access": user, "secret": "".join(secrets.choice(alphabet) for _ in range(40)),
                 "role": "user", "userID": 0, "groupID": 0, "projectID": 0}
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)
    print("created")
else:
    print("kept")
PY
  mkdir -p "$BK_STORE_DIR/data/$bec_bucket"
  bk_store_admin change-bucket-owner --bucket "$bec_bucket" --owner "$bec_user" >/dev/null
}

# bk_store_secret <cluster> - prints that cluster's S3 secret key (to be
# piped into a file, never echoed).
bk_store_secret() {
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["accessAccounts"][sys.argv[2]]["secret"], end="")' \
    "$BK_STORE_IAM" "velero-$1"
}

# bk_write_velero_values <cluster> <out> - values for the velero chart.
# No chart RBAC (its namespace Role is a wildcard and it binds
# cluster-admin): extraObjects grant exactly what backing up and restoring
# the included kinds needs. No node agent and no volume snapshots until a
# PersistentVolumeClaim exists (6.3). CRDs come from the chart's crds/
# directory on first install (no upgrade Job, no kubectl image).
bk_write_velero_values() {
  bwv_c="$1"
  bwv_ns_list="$(bk_namespaces "$bwv_c" | tr ' ' '\n' | sed 's/^/          - /')"
  cat > "$2" <<EOF
# Generated by scripts/backup/_lib.sh (Phase 6.2a, cluster ${bwv_c}).
image:
  repository: ${BK_VELERO_IMAGE_REPOSITORY}
  tag: ${BK_VELERO_IMAGE_TAG}
  digest: "${BK_VELERO_IMAGE_DIGEST}"
initContainers:
  - name: velero-plugin-for-aws
    image: ${BK_AWS_PLUGIN_IMAGE}
    imagePullPolicy: IfNotPresent
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    volumeMounts:
      - mountPath: /target
        name: plugins
upgradeCRDs: false
cleanUpCRDs: false
deployNodeAgent: false
snapshotsEnabled: false
backupsEnabled: true
podSecurityContext:
  runAsUser: 65532
  runAsGroup: 65532
  runAsNonRoot: true
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
resources:
  requests:
    cpu: 25m
    memory: 64Mi
  limits:
    memory: 256Mi
credentials:
  useSecret: true
  existingSecret: ${BK_SECRET}
rbac:
  create: false
  clusterAdministrator: false
serviceAccount:
  server:
    create: true
metrics:
  enabled: true
  serviceMonitor:
    enabled: false
  prometheusRule:
    enabled: false
configuration:
  # Velero's own backups and restores are scoped by namespace and kind
  # below; this default only applies to ad-hoc commands.
  defaultBackupTTL: 72h
  backupStorageLocation:
    - name: default
      default: true
      provider: aws
      bucket: $(bk_bucket "$bwv_c")
      accessMode: ReadWrite
      credential:
        name: ${BK_SECRET}
        key: cloud
      config:
        region: ${BK_REGION}
        s3ForcePathStyle: "true"
        # LAB-ONLY plain HTTP on the kind docker network.
        s3Url: ${BK_STORE_URL}
        # Non-AWS S3: no default request checksums (plugin note).
        checksumAlgorithm: ""
  volumeSnapshotLocation: []
schedules:
  platform-state:
    disabled: false
    schedule: "0 */6 * * *"
    useOwnerReferencesInBackup: false
    template:
      ttl: 72h
      snapshotVolumes: false
      includedNamespaces:
${bwv_ns_list}
      # Roles and RoleBindings too (6.2b drill): the ESO source Secret's
      # reader RBAC is created by the same imperative script as the
      # Secret, outside Git, and a restored Secret is useless without it.
      includedResources:
        - secrets
        - configmaps
        - roles.rbac.authorization.k8s.io
        - rolebindings.rbac.authorization.k8s.io
        - persistentvolumeclaims
        - persistentvolumes
      # Not what a chart owns (its objects and Helm's release records):
      # the install scripts recreate those; restoring them would fight
      # Helm on a rebuilt cluster.
      labelSelector:
        matchExpressions:
          - key: owner
            operator: NotIn
            values: [helm]
          - key: app.kubernetes.io/managed-by
            operator: NotIn
            values: [Helm]
extraObjects:
  # In its own namespace: its custom resources, its credential, leader
  # election.
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: velero-server
      namespace: ${BK_NAMESPACE}
    rules:
      - apiGroups: ["velero.io"]
        resources: [backups, backups/status, backupstoragelocations, backupstoragelocations/status, backuprepositories, backuprepositories/status, datadownloads, datadownloads/status, datauploads, datauploads/status, deletebackuprequests, deletebackuprequests/status, downloadrequests, downloadrequests/status, podvolumebackups, podvolumebackups/status, podvolumerestores, podvolumerestores/status, restores, restores/status, schedules, schedules/status, serverstatusrequests, serverstatusrequests/status, volumesnapshotlocations, volumesnapshotlocations/status]
        verbs: [get, list, watch, create, update, patch, delete]
      - apiGroups: ["coordination.k8s.io"]
        resources: [leases]
        verbs: [get, list, watch, create, update, patch]
      # A restore reads Velero's own Deployment (its image, for helpers).
      - apiGroups: ["apps"]
        resources: [deployments]
        verbs: [get]
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: velero-server
      namespace: ${BK_NAMESPACE}
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: velero-server
    subjects:
      - kind: ServiceAccount
        name: velero-server
        namespace: ${BK_NAMESPACE}
  # Cluster-wide: read (back up) and write (restore) exactly the kinds a
  # backup includes, the namespaces they live in, and nothing else.
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: velero-platform-state
    rules:
      - apiGroups: [""]
        resources: [secrets, configmaps, persistentvolumeclaims, persistentvolumes]
        verbs: [get, list, watch, create, update, patch]
      - apiGroups: [""]
        resources: [namespaces]
        verbs: [get, list, watch, create]
      # Read only: Velero maps PersistentVolumeClaims to the pods that
      # mount them before every backup.
      - apiGroups: [""]
        resources: [pods]
        verbs: [get, list]
      - apiGroups: [""]
        resources: [events]
        verbs: [create, patch]
      - apiGroups: ["apiextensions.k8s.io"]
        resources: [customresourcedefinitions]
        verbs: [get, list, watch]
      # Velero's built-in ServiceAccount action lists them at the start of
      # every backup, whatever the backup includes; read only.
      - apiGroups: ["rbac.authorization.k8s.io"]
        resources: [clusterrolebindings]
        verbs: [get, list]
      # Namespaced RBAC outside Git (the ESO source reader). Restoring a
      # Role or RoleBinding never grants more than Velero already holds:
      # Kubernetes refuses to create one that would escalate.
      - apiGroups: ["rbac.authorization.k8s.io"]
        resources: [roles, rolebindings]
        verbs: [get, list, watch, create, update, patch]
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: velero-platform-state
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: velero-platform-state
    subjects:
      - kind: ServiceAccount
        name: velero-server
        namespace: ${BK_NAMESPACE}
  # Ingress: only the metrics port, only from the monitoring namespace.
  - apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: velero
      namespace: ${BK_NAMESPACE}
    spec:
      podSelector: {}
      policyTypes: [Ingress]
      ingress:
        - from:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: monitoring
          ports:
            - port: 8085
              protocol: TCP
EOF
}
