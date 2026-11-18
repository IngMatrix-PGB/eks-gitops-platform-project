#!/bin/sh
# Fully offline render of Velero for every member (Phase 6.2a, ADR-0022),
# plus proof of its shape. Never touches a cluster. Backs
# `make backup-render` (needs the chart: make backup-chart-fetch; like the
# other add-on renders, not part of make validate).
#
# Proves, for hub, dev, uat and prod:
#   - the exact object set; the only images are the pinned Velero and AWS
#     plugin digests; no Secret (the key comes from the install script);
#     no node agent, no volume snapshot location, no CRD upgrade Job;
#   - RBAC: no wildcard, no binding to cluster-admin; the ClusterRole
#     covers exactly the kinds a backup holds (read and restore), namespaces
#     (create for restore) and read-only pods and clusterrolebindings; the
#     namespaced Role names Velero's own resources one by one;
#   - restricted pods (non-root, read-only root filesystem, no escalation,
#     drop ALL, RuntimeDefault);
#   - the BackupStorageLocation: this cluster's own bucket on the lab
#     store, path-style, no request checksums;
#   - the Schedule: every 6 hours, TTL 72h, exactly this member's
#     namespaces, the four kinds, Helm-owned objects excluded;
#   - a NetworkPolicy admitting only the monitoring namespace, on 8085.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/backup/_lib.sh
require_helm
require_bk_chart
# shellcheck source=../../scripts/eso/_lib.sh
LAB_CLUSTER=lab-lite . scripts/eso/_lib.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

for c in hub dev uat prod; do
  bk_write_velero_values "$c" "$work/v-$c.yaml"
  "$HELM_BIN" lint "$BK_VELERO_CHART_TGZ" -n "$BK_NAMESPACE" -f "$work/v-$c.yaml" >/dev/null 2>&1 || bad "$c: helm lint failed"
  "$HELM_BIN" template "$BK_RELEASE" "$BK_VELERO_CHART_TGZ" -n "$BK_NAMESPACE" -f "$work/v-$c.yaml" > "$work/r-$c.yaml"
  r="$work/r-$c.yaml"
  hits="$(eso_check_no_rbac_wildcards "$r" || true)"; [ -z "$hits" ] || bad "$c: RBAC wildcard: $hits"
  # Structural checks on the parsed render.
  if ! python3 -I - "$r" "$c" "$(bk_bucket "$c")" "$BK_STORE_URL" "${BK_VELERO_IMAGE_REPOSITORY}@${BK_VELERO_IMAGE_DIGEST}" "$BK_AWS_PLUGIN_IMAGE" "$(bk_namespaces "$c")" <<'PY'
import sys, yaml
path, c, bucket, url, velero_img, plugin_img, nss = sys.argv[1:8]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
errs = []
def by_kind(k): return [d for d in docs if d.get("kind") == k]
kinds = sorted(d["kind"] for d in docs)
want = sorted(["BackupStorageLocation", "ClusterRole", "ClusterRoleBinding", "ConfigMap", "Deployment",
               "NetworkPolicy", "Role", "RoleBinding", "Schedule", "Service", "ServiceAccount"])
if kinds != want: errs.append(f"object set {kinds}")
dep = by_kind("Deployment")[0]["spec"]["template"]["spec"]
imgs = sorted(x["image"] for x in dep.get("containers", []) + dep.get("initContainers", []))
if imgs != sorted([velero_img, plugin_img]): errs.append(f"images {imgs}")
psc = dep.get("securityContext", {})
if not (psc.get("runAsNonRoot") and psc.get("seccompProfile", {}).get("type") == "RuntimeDefault"): errs.append("pod not non-root/RuntimeDefault")
for ct in dep.get("containers", []) + dep.get("initContainers", []):
    sc = ct.get("securityContext", {})
    if not (sc.get("readOnlyRootFilesystem") and sc.get("allowPrivilegeEscalation") is False and "ALL" in sc.get("capabilities", {}).get("drop", [])):
        errs.append(f"container {ct['name']} not restricted")
for b in by_kind("ClusterRoleBinding") + by_kind("RoleBinding"):
    if b["roleRef"]["name"] == "cluster-admin": errs.append("binds cluster-admin")
cr = by_kind("ClusterRole")[0]["rules"]
want_cr = [(["secrets", "configmaps", "persistentvolumeclaims", "persistentvolumes"], ["get", "list", "watch", "create", "update", "patch"]),
           (["namespaces"], ["get", "list", "watch", "create"]), (["pods"], ["get", "list"]), (["events"], ["create", "patch"]),
           (["customresourcedefinitions"], ["get", "list", "watch"]), (["clusterrolebindings"], ["get", "list"])]
if [(r["resources"], r["verbs"]) for r in cr] != want_cr: errs.append(f"ClusterRole rules {[(r['resources'], r['verbs']) for r in cr]}")
role = by_kind("Role")[0]
if role["metadata"].get("namespace") != "velero": errs.append("Role outside namespace velero")
bsl = by_kind("BackupStorageLocation")[0]["spec"]
cfg = bsl.get("config", {})
if bsl["objectStorage"]["bucket"] != bucket or cfg.get("s3Url") != url or cfg.get("s3ForcePathStyle") != "true" or cfg.get("checksumAlgorithm") != "":
    errs.append(f"BackupStorageLocation {bsl}")
sch = by_kind("Schedule")[0]["spec"]
t = sch["template"]
if sch["schedule"] != "0 */6 * * *" or t.get("ttl") != "72h": errs.append("schedule or TTL")
if t.get("includedNamespaces") != nss.split(): errs.append(f"namespaces {t.get('includedNamespaces')}")
if t.get("includedResources") != ["secrets", "configmaps", "persistentvolumeclaims", "persistentvolumes"]: errs.append("included kinds")
me = {(m["key"], m["operator"], tuple(m["values"])) for m in t.get("labelSelector", {}).get("matchExpressions", [])}
if me != {("owner", "NotIn", ("helm",)), ("app.kubernetes.io/managed-by", "NotIn", ("Helm",))}: errs.append("Helm-owned objects not excluded")
if t.get("snapshotVolumes") is not False: errs.append("volume snapshots on")
np = by_kind("NetworkPolicy")[0]["spec"]
ing = np.get("ingress", [])
if len(ing) != 1 or ing[0]["from"] != [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "monitoring"}}}] or ing[0]["ports"] != [{"port": 8085, "protocol": "TCP"}]:
    errs.append("NetworkPolicy not monitoring-only on 8085")
for e in errs: print(f"FAIL: {c}: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PY
  then fail=1; fi
  [ "$fail" -eq 0 ] && ok "$c: pinned images, no Secret, least RBAC (no wildcard, no cluster-admin), restricted pod, own bucket, schedule over: $(bk_namespaces "$c")"
done
if [ "$fail" -ne 0 ]; then echo "backup-render: FAILED"; exit 1; fi
echo "backup-render: OK"
