#!/bin/sh
# Fully offline Helm render of gitops/bootstrap, plus proof that it
# renders exactly the authorized shape: one AppProject per environment
# plus the all-environment one (ADR-0026, check_projects), one
# ApplicationSet with exactly three list elements (local-kind) or exactly
# one clusters generator (local-multicluster, Phase 2.7.4; aws-eks,
# Phase 3.4.4b), zero Secrets, no
# wildcard permissions, and correct revision propagation. Never touches
# the cluster. Backs `make gitops-render`. Accepts REVISION=<value>
# (default main) to prove propagation for a non-default revision too.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh
# shellcheck source=../../scripts/gitops/_lib.sh
. scripts/gitops/_lib.sh
require_helm
# Phase 6.3c: YAML is parsed with the pinned yq (make tools-install).
YQ_BIN=".tools/bin/yq"
[ -x "$YQ_BIN" ] || { echo "FAIL: $YQ_BIN not found - run 'make tools-install'" >&2; exit 1; }

revision="${REVISION:-$GITOPS_DEFAULT_REVISION}"

echo "gitops-render: helm lint ..."
if ! "$HELM_BIN" lint gitops/bootstrap; then
  echo "FAIL: helm lint failed" >&2
  exit 1
fi
echo "OK: helm lint passed"

render_out="$(mktemp)"
cleanup() { rm -f "$render_out" "$render_out.json"; }
trap cleanup EXIT INT TERM

echo "gitops-render: rendering with gitRevision=${revision} ..."
if ! "$HELM_BIN" template gitops/bootstrap --set "gitRevision=${revision}" > "$render_out" 2>&1; then
  echo "FAIL: helm template failed" >&2
  cat "$render_out" >&2
  exit 1
fi

fail=0

# check_projects <render> <profile> (ADR-0026): the AppProjects are
# exactly <project>-<env> per environment, with no all-environment
# <project> (ADR-0026); each <project>-<env> has exactly one
# destination, its own environment (by spoke name on hub-and-spoke
# profiles, never a server; the in-cluster namespace on local-kind); every
# project has the one source repo and the same kinds; developer roles only
# on the lab hub (checked in depth by check-argocd-rbac); every generated
# Application names its environment's project.
check_projects() {
  "$YQ_BIN" -o=json ea '[select(.kind == "AppProject" or .kind == "ApplicationSet")]' "$1" > "$1.json" || { echo "FAIL: $2: render is not valid YAML" >&2; return 1; }
  python3 -I - "$1.json" "$2" "$("$YQ_BIN" -N '.project.name' gitops/bootstrap/values.yaml)" "$("$YQ_BIN" -N '.repoURL' gitops/bootstrap/values.yaml)" <<'PY'
import json, sys
docs = json.load(open(sys.argv[1])); prof, project, repo = sys.argv[2], sys.argv[3], sys.argv[4]
multi = prof in ("local-multicluster", "aws-eks"); envs = ["dev", "uat", "prod"]
fail = 0
def bad(m):
    global fail; fail = 1; print(f"FAIL: {prof}: {m}", file=sys.stderr)
projs = {d["metadata"]["name"]: d["spec"] for d in docs if d["kind"] == "AppProject"}
want = [f"{project}-{e}" for e in envs]
sorted(projs) == sorted(want) or bad(f"AppProjects {sorted(projs)}, want exactly {want}")
def dest(e): return {"name": f"spoke-{e}", "namespace": e} if multi else {"server": "https://kubernetes.default.svc", "namespace": e}
kinds = None
for name, spec in projs.items():
    spec.get("sourceRepos") == [repo] or bad(f"{name}: sourceRepos {spec.get('sourceRepos')}, want exactly [{repo}]")
    k = (json.dumps(spec.get("clusterResourceWhitelist")), json.dumps(spec.get("namespaceResourceWhitelist")))
    if kinds is None: kinds = k
    elif k != kinds: bad(f"{name}: kind whitelists differ from the other projects'")
    cw = spec.get("clusterResourceWhitelist")
    (cw == [] if multi else cw == [{"group": "", "kind": "Namespace"}]) or bad(f"{name}: clusterResourceWhitelist {cw}")
    if name not in want: continue
    e = name[len(project) + 1:]
    spec.get("destinations") == [dest(e)] or bad(f"{name}: destinations {spec.get('destinations')}, want exactly [{dest(e)}]")
    roles = [r["name"] for r in spec.get("roles") or []]
    expect = ["developer"] if prof == "local-multicluster" and e in ("dev", "uat") else []
    roles == expect or bad(f"{name}: roles {roles}, want {expect}")
ref = "{{.values.env}}" if multi else "{{.env}}"
sets = [d for d in docs if d["kind"] == "ApplicationSet"]
for d in sets:
    p = d["spec"]["template"]["spec"]["project"]
    p == f"{project}-{ref}" or bad(f"ApplicationSet {d['metadata']['name']}: project {p!r}, want '{project}-{ref}'")
fail or print(f"OK: profile={prof}: AppProjects {', '.join(want)}; each {project}-<env> deploys only to its own environment, same source and kinds everywhere; {len(sets)} ApplicationSet(s) put each Application in its environment's project")
sys.exit(fail)
PY
}
check_projects "$render_out" local-kind || fail=1
# self-test: an Application template back on the removed all-environment
# project, a second destination in platform-dev, and the project
# `platform` rendered again are all caught.
st="$(mktemp)"
"$HELM_BIN" template gitops/bootstrap --set profile=local-multicluster | sed 's#project: "platform-{{.values.env}}"#project: "platform"#' > "$st"
if check_projects "$st" local-multicluster >/dev/null 2>&1; then echo "FAIL: check_projects missed an Application template on the all-environment project - check is broken" >&2; fail=1; fi
"$HELM_BIN" template gitops/bootstrap --set profile=local-multicluster | awk '{print} /^  name: platform-dev$/{d=1} d && /^  destinations:$/{print "    - name: spoke-prod"; print "      namespace: prod"; d=0}' > "$st"
if check_projects "$st" local-multicluster >/dev/null 2>&1; then echo "FAIL: check_projects missed a second destination in platform-dev - check is broken" >&2; fail=1; fi
grep -q 'name: spoke-prod' "$st" || { echo "FAIL: self-test mutation not applied" >&2; fail=1; }
{ "$HELM_BIN" template gitops/bootstrap --set profile=local-multicluster; printf '%s\n' '---' 'apiVersion: argoproj.io/v1alpha1' 'kind: AppProject' 'metadata:' '  name: platform' '  namespace: argocd' 'spec:' '  sourceRepos: []' '  destinations: []'; } > "$st"
if check_projects "$st" local-multicluster >/dev/null 2>&1; then echo "FAIL: check_projects missed the all-environment project 'platform' coming back - check is broken" >&2; fail=1; fi
rm -f "$st" "$st.json"
echo "OK: check_projects self-test: an Application on the all-environment project, a widened platform-dev and the project platform back are all refused"

appset_count="$(grep -c '^kind: ApplicationSet$' "$render_out" || true)"
if [ "$appset_count" != "1" ]; then
  echo "FAIL: expected exactly 1 ApplicationSet, found $appset_count" >&2
  fail=1
else
  echo "OK: exactly 1 ApplicationSet rendered"
fi

secret_count="$(grep -c '^kind: Secret$' "$render_out" || true)"
if [ "$secret_count" != "0" ]; then
  echo "FAIL: expected 0 Secrets rendered, found $secret_count" >&2
  fail=1
else
  echo "OK: no Secret rendered"
fi

generator_elements="$(grep -c '^\s*- env: ' "$render_out" || true)"
if [ "$generator_elements" != "3" ]; then
  echo "FAIL: expected exactly 3 generator list elements, found $generator_elements" >&2
  fail=1
else
  echo "OK: exactly 3 generator elements (dev, uat, prod)"
fi

if grep -qE 'sourceRepos:\s*$' "$render_out" && grep -A1 'sourceRepos:' "$render_out" | grep -q '"\*"'; then
  echo "FAIL: wildcard sourceRepos detected" >&2
  fail=1
fi
if grep -qE 'namespace: "\*"|server: "\*"' "$render_out"; then
  echo "FAIL: wildcard destination detected" >&2
  fail=1
fi
if [ "$fail" -eq 0 ]; then
  echo "OK: no wildcard source/destination permissions found"
fi

if grep -q "targetRevision: ${revision}" "$render_out"; then
  echo "OK: revision '${revision}' propagated into the generated-Application template"
else
  echo "FAIL: revision '${revision}' not found in rendered targetRevision" >&2
  fail=1
fi

# =============================================================================
# Phase 3.4.4b: the default (local-kind) render never reaches a spoke or
# AWS. aws-eks and local-multicluster are both hub-and-spoke and are
# checked by check_hub_spoke below. Nothing here contacts a cluster or AWS.
# =============================================================================
if grep -qE '^\s*- clusters:$' "$render_out"; then
  echo "FAIL: the default render contains a clusters generator - a spoke profile must never activate by omission" >&2
  fail=1
else
  echo "OK: the default render (profile unset) has no clusters generator - no spoke profile activates by omission"
fi
if grep -qiE '^kind: SecretStore$|^kind: Secret$|auth:|serviceAccountRef|arn:aws:|AKIA[0-9A-Z]{16}' "$render_out"; then
  echo "FAIL: the default render contains a SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped string - this chart must never render workload-level resources at all" >&2
  fail=1
else
  echo "OK: the default render contains zero SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped content"
fi
# --- negative: an unrecognized profile value fails the render closed ---
unknown_profile_out="$(mktemp)"
if "$HELM_BIN" template gitops/bootstrap --set profile=azure > "$unknown_profile_out" 2>&1; then
  echo "FAIL: profile=azure (unknown) rendered successfully - must fail closed" >&2
  fail=1
elif grep -q 'unknown profile' "$unknown_profile_out"; then
  echo "OK: an unrecognized profile value ('azure') fails the render closed with the expected error"
else
  echo "FAIL: profile=azure failed, but not for the expected 'unknown profile' reason" >&2
  cat "$unknown_profile_out" >&2
  fail=1
fi
rm -f "$unknown_profile_out"

# --- Phase 2.8.2: local-kind lets an HPA own Deployment spec.replicas
# (ignoreDifferences on exactly that pointer + RespectIgnoreDifferences) ---
igd="$(awk '/ignoreDifferences:/{f=1} f&&/destination:/{exit} f{print}' "$render_out")"
if printf '%s\n' "$igd" | grep -qE '^\s+- group: apps$' && printf '%s\n' "$igd" | grep -qE '^\s+kind: Deployment$' \
   && ! printf '%s\n' "$igd" | grep -q 'jsonPointers:' \
   && [ "$(printf '%s\n' "$igd" | grep -cE "^\s+- 'select")" = "1" ] \
   && printf '%s\n' "$igd" | grep -qF -- "- 'select(.metadata.annotations[\"eks-gitops-lab-lite.local/replicas-owner\"] == \"hpa\") | .spec.replicas'" \
   && grep -qE '^\s+- RespectIgnoreDifferences=true$' "$render_out"; then
  echo "OK: local-kind ignores spec.replicas only on Deployments annotated replicas-owner=hpa, with RespectIgnoreDifferences=true"
else
  echo "FAIL: local-kind does not ignore exactly spec.replicas of HPA-owned Deployments (replicas-owner=hpa) with RespectIgnoreDifferences=true" >&2
  fail=1
fi

# =============================================================================
# Hub-and-spoke profiles (Phase 2.7.4 local-multicluster, Phase 3.4.4b
# aws-eks): hub Argo CD -> spokes through a clusters generator. Offline
# shape only - which spokes actually get an Application is proven at
# runtime (tests/multicluster/test-e2e.sh for the lab; Phase 6.4 for EKS).
#   check_hub_spoke <profile> <owner label value> <other profile's owner> <overlay suffix>
# =============================================================================
check_hub_spoke() {
  local prof="$1" owner="$2" other_owner="$3" suffix="$4" out hs_fail=0
  echo "gitops-render: helm lint (profile=$prof) ..."
  if ! "$HELM_BIN" lint gitops/bootstrap --set "profile=$prof" >/dev/null; then
    echo "FAIL: helm lint failed for profile=$prof" >&2
    fail=1
  fi
  out="$(mktemp)"
  if ! "$HELM_BIN" template gitops/bootstrap --set "profile=$prof" --set "gitRevision=${revision}" > "$out" 2>&1; then
    echo "FAIL: helm template failed for profile=$prof" >&2
    cat "$out" >&2
    rm -f "$out"; fail=1; return
  fi
  check_projects "$out" "$prof" || hs_fail=1
  # Phase 6.3c: smoke's ApplicationSet plus one per other component that
  # lists an environment and allows this profile.
  local want_sets
  want_sets="$(PROF="$prof" "$YQ_BIN" '[.components[] | select(.name != "smoke") | select((.environments // []) | length > 0) | select(((.profiles // [strenv(PROF)]) | contains([strenv(PROF)])))] | length + 1' gitops/bootstrap/values.yaml)"
  [ "$(grep -c '^kind: ApplicationSet$' "$out")" = "$want_sets" ] || { echo "FAIL: $prof: expected exactly $want_sets ApplicationSet(s)" >&2; hs_fail=1; }
  if grep -qiE '^kind: SecretStore$|^kind: Secret$|auth:|serviceAccountRef|arn:aws:|AKIA[0-9A-Z]{16}' "$out"; then
    echo "FAIL: $prof: render contains a SecretStore/Secret/auth/serviceAccountRef/ARN/credential-shaped string" >&2; hs_fail=1
  fi
  # one clusters generator per ApplicationSet (Phase 6.3c)
  [ "$(grep -cE '^\s*- clusters:$' "$out")" = "$want_sets" ] || { echo "FAIL: $prof: expected exactly $want_sets clusters generator(s), one per ApplicationSet" >&2; hs_fail=1; }
  [ "$(grep -cE '^\s*- list:$' "$out" || true)" = "0" ] || { echo "FAIL: $prof: a list generator is still rendered" >&2; hs_fail=1; }
  grep -qE "^\s*eks-gitops-lab-lite\.local/owner: ${owner}$" "$out" || { echo "FAIL: $prof: selector lacks owner label value '$owner'" >&2; hs_fail=1; }
  if grep -qE "owner: ${other_owner}$" "$out"; then
    echo "FAIL: $prof: selector would also match the other profile's spoke Secrets ('$other_owner')" >&2; hs_fail=1
  fi
  grep -qE '^\s*- key: platform\.environment$' "$out" || { echo "FAIL: $prof: selector lacks the platform.environment expression" >&2; hs_fail=1; }
  local sel_values
  sel_values="$(awk '/- key: platform\.environment$/{f=1} f && /^[[:space:]]*- (dev|uat|prod|[a-z-]+)$/{printf "%s ", $2} f && /values:$/ && ++v==2 {exit}' "$out")"
  [ "$sel_values" = "dev uat prod " ] || { echo "FAIL: $prof: selector environments are '$sel_values', expected exactly 'dev uat prod'" >&2; hs_fail=1; }
  local appset
  # smoke's ApplicationSet only (the first one; others follow after ---)
  appset="$(awk '/^kind: ApplicationSet$/{f=1} f && /^---/{exit} f{print}' "$out")"
  printf '%s\n' "$appset" | grep -qE '^\s*- CreateNamespace=false$' || { echo "FAIL: $prof: CreateNamespace=false missing" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -qF 'replicas-owner"] == "hpa") | .spec.replicas' && printf '%s\n' "$appset" | grep -qE '^\s+- RespectIgnoreDifferences=true$' || { echo "FAIL: $prof: HPA hand-over settings (ignoreDifferences on replicas-owner=hpa Deployments + RespectIgnoreDifferences) missing" >&2; hs_fail=1; }
  if printf '%s\n' "$appset" | grep -qE 'CreateNamespace=true|managedNamespaceMetadata:|server: https://kubernetes\.default\.svc'; then
    echo "FAIL: $prof: template still creates namespaces or targets the hub's in-cluster server" >&2; hs_fail=1
  fi
  printf '%s\n' "$appset" | grep -qE '^\s*name: "\{\{\.name\}\}"$' || { echo "FAIL: $prof: destination is not the generated cluster name" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -qE '^\s*namespace: "\{\{\.values\.env\}\}"$' || { echo "FAIL: $prof: destination namespace is not the spoke's environment" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -qF -- "- \"values-{{.values.env}}${suffix}.yaml\"" || { echo "FAIL: $prof: valueFiles is not values-{{.values.env}}${suffix}.yaml" >&2; hs_fail=1; }
  printf '%s\n' "$appset" | grep -q "targetRevision: ${revision}" || { echo "FAIL: $prof: revision '${revision}' not propagated" >&2; hs_fail=1; }
  for e in dev uat prod; do
    [ -f "charts/standard-workload/values-${e}${suffix}.yaml" ] || { echo "FAIL: $prof: values-${e}${suffix}.yaml missing" >&2; hs_fail=1; }
  done
  # self-test: an extra 'qa' environment in this profile's list is caught
  local key qa_values qa_sel
  key="$([ "$prof" = "aws-eks" ] && echo awsEks || echo multicluster)"
  qa_values="$(mktemp)"
  printf 'profile: "%s"\n%s:\n  environments: [dev, uat, prod, qa]\n' "$prof" "$key" > "$qa_values"
  qa_sel="$("$HELM_BIN" template gitops/bootstrap -f "$qa_values" 2>/dev/null | awk '/- key: platform\.environment$/{f=1} f && /^[[:space:]]*- [a-z-]+$/{printf "%s ", $2} f && /values:$/ && ++v==2 {exit}')"
  rm -f "$qa_values" "$out" "$out.json"
  if [ "$qa_sel" != "dev uat prod qa " ]; then
    echo "FAIL: $prof: selector self-test did not render the injected 'qa' environment (got '$qa_sel') - check is broken" >&2; hs_fail=1
  fi
  if [ "$hs_fail" -eq 0 ]; then
    echo "OK: profile=$prof renders its AppProjects (above) and smoke's ApplicationSet (plus one per enabled component), each with exactly 1 clusters generator (owner=$owner + platform.environment in dev/uat/prod), CreateNamespace=false, destination by cluster name, values-<env>${suffix}.yaml, revision propagated; an extra 'qa' is detectable"
  else
    fail=1
  fi
}

check_hub_spoke local-multicluster multicluster-registration eks-spoke-registration ""
check_hub_spoke aws-eks eks-spoke-registration multicluster-registration "-aws"

# =============================================================================
# Phase 6.3c (ADR-0023): one ApplicationSet per component. Proven with an
# injected component list (notes in dev, postgres in dev+uat), then the
# real values: every environment a component lists has its overlay.
# =============================================================================
comp_fail=0
comp_values="$(mktemp)"; comp_out="$(mktemp)"
cat > "$comp_values" <<'EOF'
profile: local-multicluster
components:
  - name: smoke
    chartPath: charts/standard-workload
    overlayPrefix: ""
  - name: notes
    chartPath: charts/standard-workload
    overlayPrefix: "notes-"
    profiles: [local-multicluster]
    environments: [dev]
  - name: postgres
    chartPath: charts/postgres-lab
    overlayPrefix: ""
    profiles: [local-multicluster]
    environments: [dev, uat]
EOF
if "$HELM_BIN" template gitops/bootstrap -f "$comp_values" > "$comp_out" 2>&1; then
  got="$("$YQ_BIN" -r 'select(.kind == "ApplicationSet") | [.metadata.name, .spec.template.metadata.name, .spec.template.spec.source.path, .spec.template.spec.source.helm.valueFiles[0], (.spec.generators[0].clusters.selector.matchExpressions[0].values | join(","))] | join(" ")' "$comp_out" | grep -v -e '^$' -e '^---$')"
  want="platform-environments platform-smoke-{{.values.env}} charts/standard-workload values-{{.values.env}}.yaml dev,uat,prod
platform-notes platform-notes-{{.values.env}} charts/standard-workload values-notes-{{.values.env}}.yaml dev
platform-postgres platform-postgres-{{.values.env}} charts/postgres-lab values-{{.values.env}}.yaml dev,uat"
  [ "$got" = "$want" ] || { echo "FAIL: per-component ApplicationSets differ from the expected names/paths/overlays/environments:" >&2; printf '%s\n' "$got" >&2; comp_fail=1; }
else
  echo "FAIL: render with notes/postgres enabled failed" >&2; cat "$comp_out" >&2; comp_fail=1
fi
[ "$("$HELM_BIN" template gitops/bootstrap -f "$comp_values" --set profile=aws-eks | grep -c '^kind: ApplicationSet$')" = "1" ] \
  || { echo "FAIL: aws-eks renders a lab-only component (notes/postgres)" >&2; comp_fail=1; }
sed 's/environments: \[dev\]$/environments: [qa]/' "$comp_values" > "$comp_out"
"$HELM_BIN" template gitops/bootstrap -f "$comp_out" 2>&1 | grep -q 'lists environment "qa", which profile' \
  || { echo "FAIL: a component environment outside the profile was not refused" >&2; comp_fail=1; }
grep -v '^    environments: \[dev\]$' "$comp_values" > "$comp_out"
"$HELM_BIN" template gitops/bootstrap -f "$comp_out" 2>&1 | grep -q 'component "notes" must list its environments' \
  || { echo "FAIL: a non-smoke component without an environments list was not refused" >&2; comp_fail=1; }
rm -f "$comp_values" "$comp_out"
# the real values: each listed environment has the overlay its Application reads
for row in $("$YQ_BIN" -r '.components[] | .chartPath as $c | .overlayPrefix as $p | (.environments // [])[] | $c + "|" + $p + "|" + .' gitops/bootstrap/values.yaml); do
  f="$(echo "$row" | cut -d'|' -f1)/values-$(echo "$row" | cut -d'|' -f2)$(echo "$row" | cut -d'|' -f3).yaml"
  [ -f "$f" ] || { echo "FAIL: gitops/bootstrap/values.yaml enables an environment whose overlay $f is missing" >&2; comp_fail=1; }
done
if [ "$comp_fail" -eq 0 ]; then
  echo "OK: one ApplicationSet per component (smoke keeps platform-environments/platform-smoke-<env>; notes/postgres by listed environment only, lab profile only); out-of-profile environment and missing list refused; every enabled environment has its overlay"
else
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "gitops-render: FAILED"
  exit 1
fi
echo "gitops-render: OK"
