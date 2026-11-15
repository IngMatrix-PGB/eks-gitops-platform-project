#!/bin/sh
# One-off hand-over of a Deployment's spec.replicas before a Git change
# puts it under an HPA (Phase 2.8.2). Usage:
#   sh lab/workload/hpa-handover.sh <namespace> <deployment>
# (target cluster from LAB_CLUSTER, as every lab script). Backs
# `make workload-hpa-handover`.
#
# Why: Argo CD syncs with server-side apply, and for a field it is told
# to ignore (RespectIgnoreDifferences, Deployments annotated
# replicas-owner=hpa) it stops sending it. If Argo CD's field manager is
# the only owner of spec.replicas at that moment, the API server removes
# the field and the default - 1 replica - applies until the HPA scales
# back up. Measured in Phase 2.8.2: prod dropped from 2 to 1 on the
# hand-over sync. This script server-side-applies ONLY spec.replicas,
# with its CURRENT value, under a separate field manager, so a second
# owner exists when Argo CD lets go; the HPA takes the field over the
# first time it changes the value. Run it right before the change that
# enables autoscaling for an existing Deployment. Idempotent; it never
# changes the replica count.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
require_tools

ns="${1:-}"; dep="${2:-}"
[ -n "$ns" ] && [ -n "$dep" ] || { echo "FAIL: usage: sh lab/workload/hpa-handover.sh <namespace> <deployment>" >&2; exit 1; }
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' does not match its expected identity ($IDENTITY_CASE)" >&2; exit 1; }

manager="replicas-hpa-handover"
current="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.replicas}')"
[ -n "$current" ] || { echo "FAIL: deployment $ns/$dep not found" >&2; exit 1; }

cat <<EOF | pkubectl apply --server-side --field-manager="$manager" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $dep
  namespace: $ns
spec:
  replicas: $current
EOF

owners="$(pkubectl -n "$ns" get deployment "$dep" --show-managed-fields \
  -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"|"}{.fieldsV1.f:spec.f:replicas}{"\n"}{end}' \
  | awk -F'|' '$2 != "" {print $1}' | sort -u | tr '\n' ' ')"
after="$(pkubectl -n "$ns" get deployment "$dep" -o jsonpath='{.spec.replicas}')"
case " $owners " in
  *" $manager "*) : ;;
  *) echo "FAIL: '$manager' does not own spec.replicas after the apply (owners: $owners)" >&2; exit 1 ;;
esac
[ "$after" = "$current" ] || { echo "FAIL: replica count changed ($current -> $after)" >&2; exit 1; }
echo "OK: $ns/$dep spec.replicas=$current is now also owned by '$manager' (owners: $owners) - safe to hand it to an HPA"
