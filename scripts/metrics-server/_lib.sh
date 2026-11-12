#!/bin/sh
# Shared constants and helpers for lab/metrics-server/*.sh and
# tests/workload/test-autoscaling.sh (Phase 2.8.2). POSIX shell, sourced
# only, from the repository root, after scripts/lab/_lib.sh.
#
# metrics-server is a platform component, like ESO: it creates
# cluster-scoped objects (APIService v1beta1.metrics.k8s.io,
# ClusterRoles/Bindings), so it is installed per workload cluster by a
# script with admin rights - never by Argo CD, never with a spoke's
# namespace-scoped credential, and never on the hub (no workloads there).
# One Helm release, `metrics-server`, in kube-system.

MS_CHART_VERSION="3.14.0"
MS_CHART_APP_VERSION="v0.9.0"
MS_CHART_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/metrics-server-helm-chart-3.14.0/metrics-server-3.14.0.tgz"
MS_CHART_SHA256="c2ca1185c01e6e7f53dd1b7d131f0c9b3fa50e003ed068b784563a1b5a3422a1"
MS_CHART_TGZ=".tools/charts/metrics-server-${MS_CHART_VERSION}.tgz"

# Multi-arch index digest for v0.9.0, resolved from registry.k8s.io
# (Docker-Content-Digest of the manifest list), never guessed. The chart
# renders "<repository>:<tag>", so the digest rides inside the tag value
# - the same name:tag@digest form the ESO pin uses.
MS_IMAGE_REPOSITORY="registry.k8s.io/metrics-server/metrics-server"
MS_IMAGE_DIGEST="sha256:d9862115e7c7881280d3d75ca26bda8ffc0fc213315979575bf23ce9826205c0"
MS_IMAGE_TAG="${MS_CHART_APP_VERSION}@${MS_IMAGE_DIGEST}"

MS_RELEASE="metrics-server"
MS_NAMESPACE="kube-system"
MS_APISERVICE="v1beta1.metrics.k8s.io"

HELM_BIN=".tools/bin/helm"
# shellcheck source=../lib/helm.sh
. scripts/lib/helm.sh

require_ms_chart() {
  if [ ! -f "$MS_CHART_TGZ" ]; then
    echo "FAIL: $MS_CHART_TGZ not found - run 'make metrics-server-chart-fetch' first" >&2
    exit 1
  fi
  ms_sha="$(shasum -a 256 "$MS_CHART_TGZ" | awk '{print $1}')"
  if [ "$ms_sha" != "$MS_CHART_SHA256" ]; then
    echo "FAIL: $MS_CHART_TGZ does not match the pinned checksum - run 'make metrics-server-chart-fetch' again" >&2
    exit 1
  fi
}

# Fails closed on the lab-multicluster hub, which runs no workloads.
ms_require_workload_cluster() {
  case "${LAB_CLUSTER:-lab-lite}" in
    lab-lite|dev|uat|prod) : ;;
    *) echo "FAIL: metrics-server runs only where workloads run (lab-lite or a spoke), never on cluster '${LAB_CLUSTER}'" >&2; exit 1 ;;
  esac
}

ms_release_exists() {
  phelm list -n "$MS_NAMESPACE" -o json 2>/dev/null | grep -q "\"name\":\"${MS_RELEASE}\""
}

# Writes the explicit lab values to $1. Every key is deliberate:
#   --kubelet-insecure-tls  LAB-ONLY. kind's kubelets serve self-signed
#                           certificates; EKS uses its own metrics-server
#                           add-on (TAD R-14) and never these values.
#   resources               explicit, small (measured footprint is tens
#                           of MiB); the chart default asks 200Mi.
#   apiService.insecureSkipTLSVerify  chart default (true) kept: the
#                           APIService is served by metrics-server's
#                           self-generated certificate inside the cluster.
ms_write_values() {
  cat > "$1" <<EOF
image:
  repository: ${MS_IMAGE_REPOSITORY}
  tag: "${MS_IMAGE_TAG}"
args:
  - --kubelet-insecure-tls
replicas: 1
resources:
  requests:
    cpu: 25m
    memory: 48Mi
  limits:
    cpu: 200m
    memory: 128Mi
podDisruptionBudget:
  enabled: false
addonResizer:
  enabled: false
metrics:
  enabled: false
serviceMonitor:
  enabled: false
apiService:
  create: true
  insecureSkipTLSVerify: true
EOF
}
