#!/bin/sh
# Mutating Phase 2.7.3 test: spoke registration with the hub's Argo CD
# (ADR-0015, plan decisions D1-D3). Requires REVISION (a pushed branch
# carrying lab/multicluster/probe/), an existing lab-multicluster
# profile (make lab-mc-create), Argo CD on the hub (make argocd-install
# LAB_CLUSTER=hub), and the hub's repository Secret (make
# gitops-repo-setup LAB_CLUSTER=hub). SPOKES selects the spokes under
# test (default dev,uat). Backs `make mc-test-registration`.
#
# Proves, per spoke: registration and re-registration (token rotated,
# expiry bounded); the spoke credential's RBAC is namespace-scoped only
# (negative can-i matrix); a spoke's token is rejected by every other
# spoke's API server; the hub reconciles a probe ConfigMap into the
# spoke with that credential; a destination outside the credential's
# namespace never syncs; and deregistration cuts the hub off. Ends with
# every spoke registered again and every probe object removed. Never
# prints a token - only hashes and expiry times.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
LAB_CLUSTER=hub
export LAB_CLUSTER
. scripts/lab/_lib.sh
require_repo_root
require_tools
. scripts/argocd/_lib.sh
. scripts/gitops/_lib.sh
. lab/multicluster/_lib.sh

revision="${REVISION:?REVISION is required (a pushed branch carrying lab/multicluster/probe/)}"
spokes="$(lab_mc_spokes)"
fail=0
probe_project="platform-probe"
probe_label="eks-gitops-lab-lite.local/owner=registration-probe"

read -r global_sha_before global_ctx_before <<EOF
$(global_kubeconfig_fingerprint)
EOF

# --- 0. preconditions ---
for m in "$LAB_MC_HUB" $spokes; do
  lab_mc_identity "$m" || { echo "FAIL: member '$m' is not a matching project cluster ($LAB_MC_IDENTITY_CASE)" >&2; exit 1; }
done
pkubectl -n "$ARGOCD_NAMESPACE" get secret "$GITOPS_REPO_SECRET_NAME" >/dev/null 2>&1 || { echo "FAIL: hub repository Secret missing - run 'make gitops-repo-setup LAB_CLUSTER=hub'" >&2; exit 1; }
gitops_remote_revision_exists "$revision" || { echo "FAIL: remote revision '$revision' does not exist - push it first" >&2; exit 1; }
echo "OK: step 0 - hub and spokes ($spokes) match; Argo CD and repository Secret present on the hub; revision '$revision' exists"

secret_token_sha() {
  pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$1" -o jsonpath='{.data.config}' 2>/dev/null | base64 -d | sed -n 's/.*"bearerToken": *"\([^"]*\)".*/\1/p' | shasum -a 256 | awk '{print $1}'
}

cleanup_probe() {
  for s in $LAB_MC_ALL_SPOKES; do
    for app in "probe-$s" "probe-$s-outside"; do
      pkubectl -n "$ARGOCD_NAMESPACE" delete application "$app" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
      # Only reached if the finalizer could not complete (e.g. the
      # destination was unreachable) - never leave a stuck probe behind.
      pkubectl -n "$ARGOCD_NAMESPACE" patch application "$app" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
  done
  pkubectl -n "$ARGOCD_NAMESPACE" delete appproject "$probe_project" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT INT TERM

# --- 1. register + re-register (rotation) ---
for s in $spokes; do
  sh lab/multicluster/spoke-register.sh "$s" >/dev/null
  rv1="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.metadata.resourceVersion}')"
  sha1="$(secret_token_sha "$s")"
  sh lab/multicluster/spoke-register.sh "$s" >/dev/null
  rv2="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.metadata.resourceVersion}')"
  sha2="$(secret_token_sha "$s")"
  if [ "$rv1" != "$rv2" ] && [ "$sha1" != "$sha2" ]; then
    echo "OK: '$s' re-registration rotated the token (Secret rv $rv1 -> $rv2, token sha256 changed)"
  else
    echo "FAIL: '$s' re-registration did not rotate the token (rv $rv1 -> $rv2)" >&2
    fail=1
  fi
  exp_iso="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.metadata.annotations.eks-gitops-lab-lite\.local/token-expires}')"
  exp_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$exp_iso" +%s 2>/dev/null || date -u -d "$exp_iso" +%s)"
  now="$(date -u +%s)"
  if [ "$exp_epoch" -gt "$now" ] && [ $((exp_epoch - now)) -le 86400 ]; then
    echo "OK: '$s' token expires $exp_iso (within 24h of now)"
  else
    echo "FAIL: '$s' token expiry $exp_iso is not within (now, now+24h]" >&2
    fail=1
  fi
  labels="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}/{.metadata.labels.platform\.environment}')"
  scope="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.data.namespaces}' | base64 -d)/$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.data.clusterResources}' | base64 -d)"
  if [ "$labels" = "cluster/$s" ] && [ "$scope" = "$s/false" ]; then
    echo "OK: '$s' hub Secret labelled cluster/$s, scoped namespaces=$s clusterResources=false"
  else
    echo "FAIL: '$s' hub Secret labels/scope unexpected (labels=$labels scope=$scope)" >&2
    fail=1
  fi
done

# --- 2. spoke credential RBAC: namespace-scoped only ---
can_i() {
  # $1 spoke, $2 expected yes|no, rest: can-i args
  ci_spoke="$1"; ci_expected="$2"; shift 2
  ci_actual="$(ckubectl "$ci_spoke" auth can-i "$@" --as="system:serviceaccount:${LAB_MC_ACCESS_NS}:${LAB_MC_ACCESS_SA}" 2>/dev/null || true)"
  if [ "$ci_actual" = "$ci_expected" ]; then
    echo "OK: '$ci_spoke' can-i $* -> $ci_actual"
  else
    echo "FAIL: '$ci_spoke' can-i $* -> '$ci_actual', expected '$ci_expected'" >&2
    fail=1
  fi
}
# `kubectl auth can-i` resolves the resource through API discovery first,
# so for a kind whose CRD is not installed yet (ESO arrives in the
# spokes in Phase 2.7.4) it answers "no" regardless of RBAC. A raw
# SubjectAccessReview evaluates the RBAC rules directly, CRD or not.
sar_allowed() {
  # $1 spoke, $2 apiGroup, $3 resource, $4 verb, $5 namespace
  cat <<EOF | ckubectl "$1" create -f - -o jsonpath='{.status.allowed}' 2>/dev/null
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:${LAB_MC_ACCESS_NS}:${LAB_MC_ACCESS_SA}
  groups: ["system:serviceaccounts", "system:serviceaccounts:${LAB_MC_ACCESS_NS}", "system:authenticated"]
  resourceAttributes:
    group: "$2"
    resource: "$3"
    verb: "$4"
    namespace: "$5"
EOF
}
for s in $spokes; do
  can_i "$s" yes create configmaps -n "$s"
  can_i "$s" yes patch deployments.apps -n "$s"
  for res in externalsecrets secretstores; do
    if [ "$(sar_allowed "$s" external-secrets.io "$res" create "$s")" = "true" ]; then
      echo "OK: '$s' SubjectAccessReview create $res.external-secrets.io -n $s -> allowed (CRD not installed yet; RBAC evaluated directly)"
    else
      echo "FAIL: '$s' SubjectAccessReview create $res.external-secrets.io -n $s -> not allowed" >&2
      fail=1
    fi
  done
  if [ "$(sar_allowed "$s" external-secrets.io externalsecrets create default)" = "true" ]; then
    echo "FAIL: '$s' SubjectAccessReview create externalsecrets in 'default' -> allowed, expected denied" >&2
    fail=1
  else
    echo "OK: '$s' SubjectAccessReview create externalsecrets.external-secrets.io -n default -> denied"
  fi
  can_i "$s" no get secrets -n "$s"
  can_i "$s" no list pods -n kube-system
  can_i "$s" no create configmaps -n default
  can_i "$s" no create namespaces
  can_i "$s" no create clusterroles.rbac.authorization.k8s.io
  can_i "$s" no create rolebindings.rbac.authorization.k8s.io -n "$s"
done

# --- 3. a spoke's token is rejected by every other spoke's API ---
for s in $spokes; do
  for other in $spokes; do
    [ "$s" = "$other" ] && continue
    other_server="$(ckubectl "$other" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    code="$(pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" -o jsonpath='{.data.config}' | base64 -d \
      | sed -n 's/.*"bearerToken": *"\([^"]*\)".*/Authorization: Bearer \1/p' \
      | curl -sk -o /dev/null -w '%{http_code}' -H @- "$other_server/api/v1/namespaces/$other/configmaps")"
    if [ "$code" = "401" ]; then
      echo "OK: '$s' token rejected by '$other' API server (HTTP 401)"
    else
      echo "FAIL: '$s' token against '$other' API server returned HTTP $code, expected 401" >&2
      fail=1
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "test-registration: FAILED before the reconciliation probe" >&2
  exit 1
fi

# --- 4. probe: hub reconciles into each spoke with the scoped credential ---
{
  echo "apiVersion: argoproj.io/v1alpha1"
  echo "kind: AppProject"
  echo "metadata:"
  echo "  name: $probe_project"
  echo "  namespace: $ARGOCD_NAMESPACE"
  echo "spec:"
  echo "  sourceRepos: [\"$GITOPS_REPO_URL\"]"
  echo "  destinations:"
  for s in $spokes; do
    echo "    - name: spoke-$s"
    echo "      namespace: $s"
    echo "    - name: spoke-$s"
    echo "      namespace: default"
  done
  echo "  clusterResourceWhitelist: []"
  echo "  namespaceResourceWhitelist:"
  echo "    - group: \"\""
  echo "      kind: ConfigMap"
} | pkubectl apply -f - >/dev/null

probe_app() {
  # $1 app name, $2 spoke, $3 namespace
  cat <<EOF | pkubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
  namespace: $ARGOCD_NAMESPACE
  labels:
    $probe_label_key: registration-probe
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: $probe_project
  source:
    repoURL: $GITOPS_REPO_URL
    targetRevision: $revision
    path: lab/multicluster/probe
  destination:
    name: spoke-$2
    namespace: $3
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}
probe_label_key="${probe_label%%=*}"

for s in $spokes; do
  probe_app "probe-$s" "$s" "$s"
done
for s in $spokes; do
  if gitops_wait_for_synced_healthy "probe-$s" 180; then
    if ckubectl "$s" -n "$s" get configmap registration-probe >/dev/null 2>&1; then
      echo "OK: probe ConfigMap reconciled into spoke '$s' namespace '$s' by the hub with the scoped credential"
    else
      echo "FAIL: Application probe-$s is Synced but the ConfigMap is not in spoke '$s'" >&2
      fail=1
    fi
  else
    fail=1
  fi
done

# --- 5. a destination outside the credential's namespace never syncs ---
first="$(printf '%s' "$spokes" | awk '{print $1}')"
probe_app "probe-$first-outside" "$first" "default"
sleep 60
outside_sync="$(pkubectl -n "$ARGOCD_NAMESPACE" get application "probe-$first-outside" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
if ckubectl "$first" -n default get configmap registration-probe >/dev/null 2>&1; then
  echo "FAIL: the probe reached namespace 'default' on '$first' - the credential's namespace scope did not hold" >&2
  fail=1
else
  echo "OK: probe targeting namespace 'default' on '$first' never landed (sync status '${outside_sync:-none}') - outside the credential's scope"
fi
pkubectl -n "$ARGOCD_NAMESPACE" delete application "probe-$first-outside" --ignore-not-found --wait=false >/dev/null 2>&1 || true
pkubectl -n "$ARGOCD_NAMESPACE" patch application "probe-$first-outside" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true

# --- 6. deregistration cuts the hub off ---
ckubectl "$first" -n "$first" delete configmap registration-probe --ignore-not-found >/dev/null
sh lab/multicluster/spoke-deregister.sh "$first" >/dev/null
pkubectl -n "$ARGOCD_NAMESPACE" annotate application "probe-$first" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
sleep 45
if ckubectl "$first" -n "$first" get configmap registration-probe >/dev/null 2>&1; then
  echo "FAIL: after deregistration the hub still reconciled the probe into '$first'" >&2
  fail=1
else
  echo "OK: after deregistering '$first', the hub can no longer reconcile into it (probe not recreated)"
fi
if pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$first" >/dev/null 2>&1; then
  echo "FAIL: hub cluster Secret spoke-$first still present after deregistration" >&2
  fail=1
fi
ns_gone=0
for _ in $(seq 1 30); do
  ckubectl "$first" get namespace "$LAB_MC_ACCESS_NS" >/dev/null 2>&1 || { ns_gone=1; break; }
  sleep 3
done
if [ "$ns_gone" -eq 1 ]; then
  echo "OK: '$LAB_MC_ACCESS_NS' (and with it every token issued for $LAB_MC_ACCESS_SA) is gone from '$first'"
else
  echo "FAIL: '$LAB_MC_ACCESS_NS' still present on '$first' 90s after deregistration" >&2
  fail=1
fi
pkubectl -n "$ARGOCD_NAMESPACE" patch application "probe-$first" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
pkubectl -n "$ARGOCD_NAMESPACE" delete application "probe-$first" --ignore-not-found --wait=false >/dev/null 2>&1 || true

# --- 7. restore: register again, remove every probe object ---
sh lab/multicluster/spoke-register.sh "$first" >/dev/null
for s in $spokes; do
  pkubectl -n "$ARGOCD_NAMESPACE" delete application "probe-$s" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
done
cleanup_probe
trap - EXIT INT TERM
for s in $spokes; do
  ckubectl "$s" -n "$s" delete configmap -l "$probe_label" --ignore-not-found >/dev/null
  if ckubectl "$s" -n "$s" get configmap registration-probe >/dev/null 2>&1; then
    echo "FAIL: probe ConfigMap left behind in '$s'" >&2
    fail=1
  fi
  pkubectl -n "$ARGOCD_NAMESPACE" get secret "spoke-$s" >/dev/null 2>&1 || { echo "FAIL: '$s' not registered at the end" >&2; fail=1; }
done
echo "OK: step 7 - every spoke registered again, every probe Application/AppProject/ConfigMap removed"

read -r global_sha_after global_ctx_after <<EOF
$(global_kubeconfig_fingerprint)
EOF
if [ "$global_sha_before" = "$global_sha_after" ] && [ "$global_ctx_before" = "$global_ctx_after" ]; then
  echo "OK: global kubeconfig hash and current-context unchanged throughout"
else
  echo "FAIL: global kubeconfig or current-context changed" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-registration: FAILED"
  exit 1
fi
echo "test-registration: OK"
