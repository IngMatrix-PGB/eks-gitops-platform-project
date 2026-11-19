#!/usr/bin/env bash
# Phase 6.3b (ADR-0023): offline contract of charts/postgres-lab. Part of
# make validate; needs the pinned helm and yq (make tools-install).
#
#   - exactly: ServiceAccount, SecretStore, ExternalSecret, ConfigMap
#     (init), two Services, StatefulSet, NetworkPolicy - never a Secret;
#   - the image is pinned by digest;
#   - the pod: non-root (999), RuntimeDefault, no service account token,
#     no service links; the container: read-only root filesystem, no
#     escalation, all capabilities dropped; writable paths are the data
#     PVC and two size-limited emptyDirs only;
#   - passwords: only as files from the ESO-built Secret (POSTGRES_PASSWORD_
#     FILE); no password value anywhere in the render; the init script
#     reads the application password inside psql, never on argv; the
#     application role is not a superuser;
#   - the PVC survives deleting or scaling the StatefulSet;
#   - NetworkPolicy: 5432 only from the configured client pods, no egress;
#   - the schema refuses a tag-only image, an unknown key, no client
#     labels, and "postgres" as the application user.
set -euo pipefail
CHART="charts/postgres-lab"
HELM=".tools/bin/helm"
YQ=".tools/bin/yq"
for b in "$HELM" "$YQ"; do [ -x "$b" ] || { echo "FAIL: $b not found - run 'make tools-install'" >&2; exit 1; }; done
command -v jq >/dev/null || { echo "FAIL: jq not found" >&2; exit 1; }
root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT INT TERM
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "OK: $*"; }

cat > "$root/v.yaml" <<'YAML'
credentials:
  secretStoreName: dev-postgres-backend
  authServiceAccountName: dev-postgres-reader
  sourceNamespace: eso-source-dev
  sourceSecretName: db-dev
networkPolicy:
  clientPodLabels:
    app.kubernetes.io/instance: platform-notes-dev
YAML
"$HELM" lint "$CHART" -f "$root/v.yaml" >/dev/null || bad "helm lint failed"
"$HELM" template platform-postgres-dev "$CHART" -n dev -f "$root/v.yaml" > "$root/r.yaml"
"$YQ" eval-all -o=json '[.]' "$root/r.yaml" | jq '[.[] | select(. != null)]' > "$root/r.json"
q() { jq -r "$1" "$root/r.json"; }

kinds="$(q '[.[].kind] | sort | join(" ")')"
[ "$kinds" = "ConfigMap ExternalSecret NetworkPolicy SecretStore Service Service ServiceAccount StatefulSet" ] \
  && ok "exact object set: $kinds" || bad "object set: $kinds"
img="$(q '.[] | select(.kind=="StatefulSet") | .spec.template.spec.containers[0].image')"
[[ "$img" =~ ^docker\.io/library/postgres@sha256:[a-f0-9]{64}$ ]] && ok "image pinned by digest" || bad "image '$img'"

sts='.[] | select(.kind=="StatefulSet") | .spec'
[ "$(q "$sts.template.spec | [.automountServiceAccountToken, .enableServiceLinks, .securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.seccompProfile.type] | join(\",\")")" = "false,false,true,999,RuntimeDefault" ] \
  || bad "pod security context"
[ "$(q "$sts.template.spec.containers[0].securityContext | [.readOnlyRootFilesystem, .allowPrivilegeEscalation, (.capabilities.drop|join(\"\"))] | join(\",\")")" = "true,false,ALL" ] \
  || bad "container security context"
mounts="$(q "$sts.template.spec.containers[0].volumeMounts | map(select(.readOnly != true) | .mountPath) | sort | join(\" \")")"
[ "$mounts" = "/tmp /var/lib/postgresql /var/run/postgresql" ] || bad "writable mounts: $mounts"
[ "$(q "$sts.template.spec.volumes | map(select(.emptyDir != null) | .emptyDir.sizeLimit) | length")" = 2 ] \
  && [ "$(q "$sts.template.spec.volumes | map(select(.emptyDir != null and .emptyDir.sizeLimit == null)) | length")" = 0 ] || bad "emptyDirs without size limits"
[ "$fail" -eq 0 ] && ok "restricted pod: non-root 999, no token, read-only root, drop ALL; writable only the PVC and two size-limited emptyDirs"

[ "$(q "$sts.template.spec.containers[0].env | map(select(.name|test(\"PASSWORD\"))) | map(.name + \"=\" + .value) | join(\" \")")" = "POSTGRES_PASSWORD_FILE=/run/secrets/postgres/superuser-password" ] \
  || bad "password environment is not file-only"
grep -qiE '(password|PASSWORD)[^_A-Za-z]*[:=] *["'"'"']?[A-Za-z0-9]{8,}' "$root/r.yaml" && bad "a password-looking value in the render"
init="$(q '.[] | select(.kind=="ConfigMap") | .data["10-app-role.sh"]')"
grep -qF '\set app_password `cat /run/secrets/postgres/app-password`' <<<"$init" && grep -qF 'NOSUPERUSER' <<<"$init" \
  && ! grep -qE 'psql[^\n]*(--set|-v app_password)' <<<"$init" || bad "init script: password on argv or role not restricted"
[ "$(q '.[] | select(.kind=="ExternalSecret") | .spec.data | map(.secretKey) | join(",")')" = "superuser-password,app-password" ] || bad "ExternalSecret keys"
[ "$fail" -eq 0 ] && ok "passwords only as ESO-built files; none in the render; init reads the app password inside psql; app role NOSUPERUSER"

[ "$(q "$sts.persistentVolumeClaimRetentionPolicy | [.whenDeleted, .whenScaled] | join(\",\")")" = "Retain,Retain" ] \
  && ok "PVC retained when the StatefulSet is deleted or scaled" || bad "PVC retention"
np='.[] | select(.kind=="NetworkPolicy") | .spec'
[ "$(q "$np | [(.policyTypes|join(\"+\")), (.ingress|length), (.ingress[0].from[0].podSelector.matchLabels[\"app.kubernetes.io/instance\"]), (.ingress[0].ports[0].port), (.egress|length)] | join(\",\")")" = "Ingress+Egress,1,platform-notes-dev,postgres,0" ] \
  && ok "NetworkPolicy: 5432 only from platform-notes-dev pods; no egress" || bad "NetworkPolicy shape"

neg() { # $1=description $2=extra values
  printf '%s\n' "$2" > "$root/neg.yaml"
  if "$HELM" template x "$CHART" -f "$root/v.yaml" -f "$root/neg.yaml" >/dev/null 2>&1; then bad "schema accepted: $1"; else ok "schema refuses: $1"; fi
}
neg "a tag-only image" 'image:
  repository: docker.io/library/postgres
  digest: "18.6"'
neg "an unknown key" 'superuserPassword: hunter2'
# Helm merges maps, so "no client labels" needs values without them.
grep -v -e '^networkPolicy:' -e 'clientPodLabels:' -e 'app.kubernetes.io/instance:' "$root/v.yaml" > "$root/nolabels.yaml"
if "$HELM" template x "$CHART" -f "$root/nolabels.yaml" >/dev/null 2>&1; then bad "schema accepted: no client pod labels"; else ok "schema refuses: no client pod labels"; fi
neg "postgres as the application user" 'appUser: postgres'

[ "$fail" -eq 0 ] || { echo "check-postgres-lab-chart: FAILED"; exit 1; }
echo "check-postgres-lab-chart: OK"
