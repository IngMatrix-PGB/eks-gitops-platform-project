#!/bin/sh
# Fully offline render of the pinned metrics-server chart with the lab
# values, plus proof of its shape (Phase 2.8.2). Never touches a
# cluster. Backs `make metrics-server-render` / `check-metrics-server-chart`.
#
# Proves: the exact set of rendered objects (no PDB, no addon-resizer,
# no ServiceMonitor, no PSP); every image is the pinned digest; the RBAC
# has no wildcard; the container is non-root, read-only, all capabilities
# dropped, no privilege escalation, RuntimeDefault seccomp; the
# --kubelet-insecure-tls flag is present (lab-only) and nothing runs on
# the host network.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/metrics-server/_lib.sh
require_helm
require_ms_chart
# eso_check_no_rbac_wildcards: the same structural RBAC scanner ESO uses.
# shellcheck source=../../scripts/eso/_lib.sh
LAB_CLUSTER=lab-lite . scripts/eso/_lib.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
ms_write_values "$work/values.yaml"
"$HELM_BIN" lint "$MS_CHART_TGZ" -f "$work/values.yaml" >/dev/null || { echo "FAIL: helm lint failed" >&2; exit 1; }
"$HELM_BIN" template "$MS_RELEASE" "$MS_CHART_TGZ" -n "$MS_NAMESPACE" -f "$work/values.yaml" > "$work/render.yaml"
fail=0

kinds="$(grep -E '^kind: ' "$work/render.yaml" | sort | uniq -c | awk '{print $2" "$3"x"$1}' | tr '\n' ' ')"
expected="kind: APIServicex1 kind: ClusterRolex2 kind: ClusterRoleBindingx2 kind: Deploymentx1 kind: RoleBindingx1 kind: Servicex1 kind: ServiceAccountx1 "
if [ "$kinds" = "$expected" ]; then
  echo "OK: exact object set rendered: $kinds"
else
  echo "FAIL: rendered object set '$kinds', expected '$expected'" >&2; fail=1
fi
images="$(sed -n 's/^[[:space:]]*image: //p' "$work/render.yaml" | tr -d '"' | sort -u)"
if [ "$images" = "${MS_IMAGE_REPOSITORY}:${MS_IMAGE_TAG}" ]; then
  echo "OK: the only image is the pinned digest ${MS_IMAGE_REPOSITORY}@${MS_IMAGE_DIGEST}"
else
  echo "FAIL: unexpected image reference(s): $images" >&2; fail=1
fi
hits="$(eso_check_no_rbac_wildcards "$work/render.yaml" || true)"
if [ -z "$hits" ]; then echo "OK: no RBAC wildcard"; else echo "FAIL: RBAC wildcard: $hits" >&2; fail=1; fi
for needle in 'allowPrivilegeEscalation: false' 'readOnlyRootFilesystem: true' 'runAsNonRoot: true' 'type: RuntimeDefault' '- ALL'; do
  grep -qF -- "$needle" "$work/render.yaml" || { echo "FAIL: container security field missing: $needle" >&2; fail=1; }
done
grep -q 'hostNetwork: true' "$work/render.yaml" && { echo "FAIL: renders hostNetwork: true" >&2; fail=1; }
grep -qF -- '- --kubelet-insecure-tls' "$work/render.yaml" || { echo "FAIL: --kubelet-insecure-tls missing (kind kubelets serve self-signed certificates)" >&2; fail=1; }
[ "$fail" -eq 0 ] && echo "OK: restricted container security context, no host network, --kubelet-insecure-tls present (lab-only)"

if [ "$fail" -ne 0 ]; then echo "metrics-server-render: FAILED"; exit 1; fi
echo "metrics-server-render: OK"
