#!/usr/bin/env bash
# Phase 3.4.4a (TAD R-05, ADR-0015): offline proof that the one Role the
# hub's Argo CD gets inside a spoke namespace
# (platform/spoke-access/role.yaml - used by the lab and by EKS) grants
# exactly what Argo CD may manage there and nothing else:
#   - exactly one document, kind Role (never a ClusterRole), namespaced by
#     the SPOKE_NAMESPACE placeholder;
#   - its (apiGroup, resource) set equals the platform AppProject's
#     namespaceResourceWhitelist (gitops/bootstrap/templates/appproject.yaml),
#     kind for kind - so the two can never drift apart;
#   - never secrets, never a wildcard, and every rule's verbs are exactly
#     get/list/watch/create/update/patch/delete.
# Fully offline; part of `make validate`.
set -euo pipefail

ROLE="platform/spoke-access/role.yaml"
PROJECT="gitops/bootstrap/templates/appproject.yaml"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

[ -f "$ROLE" ] || { echo "FAIL: $ROLE not found" >&2; exit 1; }
[ -f "$PROJECT" ] || { echo "FAIL: $PROJECT not found" >&2; exit 1; }

body="$(grep -v '^[[:space:]]*#' "$ROLE")"

[ "$(printf '%s\n' "$body" | grep -cE '^kind: ')" = "1" ] || bad "$ROLE must hold exactly one document"
printf '%s\n' "$body" | grep -qE '^kind: Role$' || bad "$ROLE must be a namespaced Role"
printf '%s\n' "$body" | grep -q 'ClusterRole' && bad "$ROLE must never reference a ClusterRole"
printf '%s\n' "$body" | grep -qE '^  namespace: SPOKE_NAMESPACE$' || bad "$ROLE must be namespaced by the SPOKE_NAMESPACE placeholder"
printf '%s\n' "$body" | grep -qE '"\*"|\[\*\]|: \*$' && bad "$ROLE must never use a wildcard"
printf '%s\n' "$body" | grep -qE '"secrets"' && bad "$ROLE must never grant secrets"

want_verbs='["get", "list", "watch", "create", "update", "patch", "delete"]'
while IFS= read -r v; do
  [ "$v" = "$want_verbs" ] || bad "$ROLE rule verbs are '$v', expected exactly $want_verbs"
done < <(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*verbs: //p')

# (group/resource) pairs granted by the Role
role_pairs="$(printf '%s\n' "$body" | awk '
  /apiGroups:/ { g = $0; sub(/.*\[/, "", g); sub(/\].*/, "", g); gsub(/[" ]/, "", g) }
  /resources:/ { r = $0; sub(/.*\[/, "", r); sub(/\].*/, "", r); gsub(/[" ]/, "", r)
                 n = split(r, a, ","); for (i = 1; i <= n; i++) print g "/" a[i] }' | sort)"

# (group/resource) pairs the AppProject allows; Kind -> plural resource
project_pairs="$(awk '/namespaceResourceWhitelist:/ {f=1; next} f && /^  [a-zA-Z]/ {f=0}
  f && /group:/ { g = $0; sub(/.*group: */, "", g); gsub(/"/, "", g) }
  f && /kind:/  { k = $0; sub(/.*kind: */, "", k); print g "/" k }' "$PROJECT" \
  | awk -F/ '{ r = tolower($2); if (r ~ /y$/) { sub(/y$/, "ies", r) } else { r = r "s" }; print $1 "/" r }' | sort)"

if [ -z "$project_pairs" ]; then
  bad "could not read namespaceResourceWhitelist from $PROJECT"
elif [ "$role_pairs" = "$project_pairs" ]; then
  echo "OK: $ROLE grants exactly the AppProject's $(printf '%s\n' "$project_pairs" | grep -c .) namespaced kinds ($(printf '%s\n' "$role_pairs" | tr '\n' ' '))"
else
  bad "$ROLE and the AppProject's namespaceResourceWhitelist differ"
  diff <(printf '%s\n' "$project_pairs") <(printf '%s\n' "$role_pairs") | sed 's/^/      /' >&2 || true
fi

if [ "$fail" -ne 0 ]; then echo "check-spoke-access: FAILED"; exit 1; fi
echo "OK: one namespaced Role, no ClusterRole, no secrets, no wildcard, exact verbs"
echo "check-spoke-access: OK"
