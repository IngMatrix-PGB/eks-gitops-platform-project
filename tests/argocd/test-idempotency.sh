#!/bin/sh
# Mutating lifecycle test proving Argo CD install/no-op/uninstall
# idempotency end to end:
#   install -> install (true no-op) -> status -> runtime-health ->
#   uninstall (CRDs retained) -> uninstall (no-op) -> restoration
#   install (retained CRDs still compatible).
#
# "True no-op" is proven empirically, not asserted: the Helm release
# revision, the live manifest checksum, and every managed workload's
# .metadata.generation are captured before and after the second
# install and must be byte-identical - proving no `helm upgrade` was
# actually issued and no rollout occurred.
#
# Leaves Argo CD installed at the end (the restoration install). Backs
# `make argocd-test-lifecycle` only.
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

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity - run 'make lab-create' first" >&2
  exit 1
fi
require_helm
require_argocd_chart

WORKLOADS="deployment/argocd-applicationset-controller deployment/argocd-repo-server deployment/argocd-server deployment/argocd-redis statefulset/argocd-application-controller"

capture_fingerprint() {
  # `helm status -o json` embeds the chart's full NOTES.txt, which
  # contains many unrelated "version"-looking substrings (CRD schema
  # text) that a naive greedy match against the whole payload can pick
  # up instead of the real top-level revision. `helm get metadata -o
  # json` returns a small, notes-free payload with a single, unambiguous
  # "revision" key.
  rev="$(phelm get metadata "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null | sed -n 's/.*"revision":\([0-9]*\).*/\1/p')"
  manifest_raw="$(mktemp)"
  manifest_norm="$(mktemp)"
  phelm get manifest "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE" > "$manifest_raw" 2>/dev/null
  sed -e 's/[[:space:]]*$//' "$manifest_raw" > "${manifest_norm}.tmp" \
    && printf '%s\n' "$(cat "${manifest_norm}.tmp")" > "$manifest_norm" \
    && rm -f "${manifest_norm}.tmp"
  manifest_sha="$(shasum -a 256 "$manifest_norm" | awk '{print $1}')"
  rm -f "$manifest_raw" "$manifest_norm"

  gens=""
  for w in $WORKLOADS; do
    kind_part="${w%%/*}"; name_part="${w#*/}"
    g="$(pkubectl -n "$ARGOCD_NAMESPACE" get "$kind_part" "$name_part" -o jsonpath='{.metadata.generation}' 2>/dev/null)"
    gens="${gens}${w}=${g};"
  done

  printf 'revision=%s;manifest_sha=%s;%s' "$rev" "$manifest_sha" "$gens"
}

echo "test-idempotency(argocd): step 1 - initial 'argocd-install'"
sh lab/argocd/install.sh
if ! argocd_release_exists; then
  echo "FAIL: step 1 - release not present after install" >&2
  exit 1
fi
fp_after_install="$(capture_fingerprint)"
echo "OK: step 1 - initial install succeeded"
echo "    fingerprint: $fp_after_install"

echo "test-idempotency(argocd): step 2 - second 'argocd-install' must be a true no-op"
sh lab/argocd/install.sh
fp_after_second_install="$(capture_fingerprint)"
if [ "$fp_after_install" != "$fp_after_second_install" ]; then
  echo "FAIL: step 2 - fingerprint changed after the second install (revision/manifest/generation drift - not a true no-op)" >&2
  echo "      before: $fp_after_install" >&2
  echo "      after:  $fp_after_second_install" >&2
  exit 1
fi
echo "OK: step 2 - second install was a true no-op (revision, manifest sha256, and every workload generation unchanged)"

echo "test-idempotency(argocd): step 3 - 'argocd-status'"
sh lab/argocd/status.sh
echo "OK: step 3 - status report succeeded"

echo "test-idempotency(argocd): step 4 - runtime health checks"
sh tests/argocd/test-runtime-health.sh
echo "OK: step 4 - runtime health checks passed"

echo "test-idempotency(argocd): step 5 - initial 'argocd-uninstall'"
sh lab/argocd/uninstall.sh
if argocd_release_exists; then
  echo "FAIL: step 5 - release still present after uninstall" >&2
  exit 1
fi
if ! detect_crd_state || [ "$CRD_STATE" != "retained" ]; then
  echo "FAIL: step 5 - expected CRD_STATE=retained after uninstall, got '${CRD_STATE:-unknown}'" >&2
  exit 1
fi
if ! check_no_unexpected_argoproj_crds; then
  exit 1
fi
if ! check_crd_compatibility; then
  echo "FAIL: step 5 - retained CRDs are not compatible with the pinned chart" >&2
  exit 1
fi
echo "OK: step 5 - uninstall succeeded; exactly the 3 expected CRDs retained and schema-compatible"

echo "test-idempotency(argocd): step 6 - second 'argocd-uninstall' must be an exit-0 no-op"
sh lab/argocd/uninstall.sh
echo "OK: step 6 - second uninstall was a no-op (exit 0)"

echo "test-idempotency(argocd): step 7 - restoration 'argocd-install' with CRDs already retained"
sh lab/argocd/install.sh
if ! argocd_release_exists; then
  echo "FAIL: step 7 - release not present after restoration install" >&2
  exit 1
fi
if ! check_argocd_install_identity; then
  echo "FAIL: step 7 - restored release does not match the pinned chart/values/manifest (case '${ARGOCD_INSTALL_CASE:-unknown}')" >&2
  exit 1
fi
if ! detect_crd_state || [ "$CRD_STATE" != "retained" ]; then
  echo "FAIL: step 7 - expected CRD_STATE=retained after restoration install, got '${CRD_STATE:-unknown}'" >&2
  exit 1
fi
echo "OK: step 7 - restoration install succeeded using the retained, schema-compatible CRDs"

echo "test-idempotency(argocd): step 8 - runtime health checks against the restored release"
sh tests/argocd/test-runtime-health.sh
echo "OK: step 8 - restored release is healthy"

echo "test-idempotency(argocd): OK - install/no-op/status/health/uninstall/no-op/restore lifecycle proven; argocd left installed and healthy"
