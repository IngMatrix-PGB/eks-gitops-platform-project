#!/bin/sh
# Phase 2.6.3b regressions (Gap 4 + Gap 5). Two independent parts:
#
#   PART 1 - lab/eso/provision-source-secret.sh's ensure/--rotate/
#   --delete semantics, proven against the real eks-gitops-lab-lite
#   cluster's actual staging/production source Secrets - restores
#   whatever value existed before this test ran (or removes what it
#   created, if nothing existed) so the persistent lab baseline is
#   never left in a test-only state.
#
#   PART 2 - the global_kubeconfig_fingerprint/
#   assert_kubeconfig_paths_distinct helpers (scripts/lab/_lib.sh),
#   proven entirely offline with synthetic, credential-free fixture
#   files under this session's own scratch/tmp area - never touches
#   the real $HOME.
#
# Never prints a decoded secret value or kubeconfig content anywhere -
# only names, hashes, sizes, UIDs, resourceVersions, and states. Backs
# `make eso-test-provision-source-secret-idempotency` only.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

fail=0

secret_hash() {
  # $1=namespace $2=secret-name - never prints the decoded value.
  pkubectl get secret "$2" -n "$1" -o jsonpath='{.data.message}' 2>/dev/null | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}'
}
secret_uid() { pkubectl get secret "$2" -n "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null; }
secret_rv() { pkubectl get secret "$2" -n "$1" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null; }

echo "=== PART 1: lab/eso/provision-source-secret.sh idempotency (Gap 4) ==="

echo "--- static gates: no --from-literal, ensure path never applies, rotate is the only mutating flag ---"
# Searches for an actual invocation ("--from-literal=..."), not just
# the string mentioned in this file's own explanatory comments about
# what it deliberately does NOT do.
if grep -q -- "--from-literal=" lab/eso/provision-source-secret.sh; then
  echo "FAIL: lab/eso/provision-source-secret.sh uses --from-literal" >&2
  fail=1
else
  echo "OK: --from-literal is never used"
fi
if ! grep -q -- "--rotate" lab/eso/provision-source-secret.sh; then
  echo "FAIL: --rotate is not implemented" >&2
  fail=1
else
  echo "OK: --rotate exists as an explicit flag"
fi

if [ "$fail" -ne 0 ]; then
  echo "test-provision-source-secret-idempotency: FAILED static gates" >&2
  exit 1
fi

staging_ns="eso-source-staging"; staging_secret="local-backend-staging"
production_ns="eso-source-production"; production_secret="local-backend-production"

staging_existed=0
pkubectl get secret "$staging_secret" -n "$staging_ns" >/dev/null 2>&1 && staging_existed=1
production_existed=0
pkubectl get secret "$production_secret" -n "$production_ns" >/dev/null 2>&1 && production_existed=1

restore_state() {
  # Best-effort restoration, run at the very end regardless of pass/
  # fail - never leaves the persistent lab baseline in a test-only
  # rotated state, and never leaves a Secret this test created behind
  # if it did not exist beforehand.
  if [ "$staging_existed" -eq 1 ] && [ -n "${staging_original_value:-}" ]; then
    printf '%s' "$staging_original_value" | sh lab/eso/provision-source-secret.sh staging --rotate >/dev/null 2>&1 || true
  elif [ "$staging_existed" -eq 0 ]; then
    sh lab/eso/provision-source-secret.sh staging --delete >/dev/null 2>&1 || true
  fi
  if [ "$production_existed" -eq 1 ] && [ -n "${production_original_value:-}" ]; then
    printf '%s' "$production_original_value" | sh lab/eso/provision-source-secret.sh production --rotate >/dev/null 2>&1 || true
  elif [ "$production_existed" -eq 0 ]; then
    sh lab/eso/provision-source-secret.sh production --delete >/dev/null 2>&1 || true
  fi
}
trap restore_state EXIT INT TERM

if [ "$staging_existed" -eq 1 ]; then
  echo "OK: staging source Secret already exists - will test ensure/no-op/rotate/isolation against it, restoring its exact current value at the end"
  # Establish a KNOWN baseline value (never read back the real one) so
  # this test can prove a real, verifiable rotation without ever
  # depending on whatever value happened to be there before.
  staging_original_value="idempotency-test-baseline-$(date +%s)-$(head -c 8 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
  printf '%s' "$staging_original_value" | sh lab/eso/provision-source-secret.sh staging --rotate >/dev/null
else
  echo "OK: staging source Secret is absent - will test the create path, then remove what this test creates"
  staging_original_value="idempotency-test-created-$(date +%s)-$(head -c 8 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
  printf '%s' "$staging_original_value" | sh lab/eso/provision-source-secret.sh staging >/dev/null
fi
baseline_uid="$(secret_uid "$staging_ns" "$staging_secret")"
baseline_rv="$(secret_rv "$staging_ns" "$staging_secret")"
baseline_hash="$(secret_hash "$staging_ns" "$staging_secret")"
echo "OK: established a known staging baseline (uid=$baseline_uid rv=$baseline_rv sha256=$baseline_hash)"

echo "--- ensure (no flag), Secret exists: must be a TRUE no-op even with a DIFFERENT piped value ---"
printf '%s' "definitely-a-different-value-$(date +%s)" | sh lab/eso/provision-source-secret.sh staging
post_ensure_uid="$(secret_uid "$staging_ns" "$staging_secret")"
post_ensure_rv="$(secret_rv "$staging_ns" "$staging_secret")"
post_ensure_hash="$(secret_hash "$staging_ns" "$staging_secret")"
if [ "$post_ensure_uid" = "$baseline_uid" ] && [ "$post_ensure_rv" = "$baseline_rv" ] && [ "$post_ensure_hash" = "$baseline_hash" ]; then
  echo "OK: ensure was a true no-op - UID/resourceVersion/hash all unchanged"
else
  echo "FAIL: ensure mutated an existing Secret (uid: $baseline_uid -> $post_ensure_uid; rv: $baseline_rv -> $post_ensure_rv; hash: $baseline_hash -> $post_ensure_hash)" >&2
  fail=1
fi

echo "--- ensure with NO stdin content at all (interactive-shaped call from a script) must still no-op without hanging or reading ---"
if printf '%s' "yet-another-different-value" | sh lab/eso/provision-source-secret.sh staging; then
  post_ensure2_hash="$(secret_hash "$staging_ns" "$staging_secret")"
  if [ "$post_ensure2_hash" = "$baseline_hash" ]; then
    echo "OK: a second ensure call remains a no-op (hash still $post_ensure2_hash)"
  else
    echo "FAIL: a second ensure call changed the hash" >&2
    fail=1
  fi
else
  echo "FAIL: ensure call failed unexpectedly" >&2
  fail=1
fi

echo "--- RBAC/namespace preserved across ensure (resourceVersion unchanged) ---"
role_rv_before="$(pkubectl get role "${staging_secret}-reader" -n "$staging_ns" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
printf '%s' "irrelevant-value" | sh lab/eso/provision-source-secret.sh staging >/dev/null
role_rv_after="$(pkubectl get role "${staging_secret}-reader" -n "$staging_ns" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
if [ "$role_rv_before" = "$role_rv_after" ]; then
  echo "OK: Role/RoleBinding untouched across ensure (resourceVersion unchanged: $role_rv_after)"
else
  echo "FAIL: Role resourceVersion changed across a true no-op ($role_rv_before -> $role_rv_after)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-provision-source-secret-idempotency: FAILED before rotate testing" >&2
  exit 1
fi

echo "--- --rotate: must change resourceVersion/hash, preserve UID, never print the value ---"
staging_rotated_value="rotated-synthetic-value-$(date +%s)-$(head -c 8 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
staging_rotated_hash="$(printf '%s' "$staging_rotated_value" | shasum -a 256 | awk '{print $1}')"
printf '%s' "$staging_rotated_value" | sh lab/eso/provision-source-secret.sh staging --rotate
post_rotate_uid="$(secret_uid "$staging_ns" "$staging_secret")"
post_rotate_rv="$(secret_rv "$staging_ns" "$staging_secret")"
post_rotate_hash="$(secret_hash "$staging_ns" "$staging_secret")"
if [ "$post_rotate_uid" != "$baseline_uid" ]; then
  echo "FAIL: rotate changed the Secret UID ($baseline_uid -> $post_rotate_uid) - must be an update, never delete+recreate" >&2
  fail=1
elif [ "$post_rotate_rv" = "$baseline_rv" ]; then
  echo "FAIL: rotate did not change resourceVersion" >&2
  fail=1
elif [ "$post_rotate_hash" != "$staging_rotated_hash" ]; then
  echo "FAIL: rotate did not apply the new value (unexpected hash $post_rotate_hash)" >&2
  fail=1
else
  echo "OK: rotate changed resourceVersion ($baseline_rv -> $post_rotate_rv) and hash ($baseline_hash -> $post_rotate_hash), UID unchanged ($post_rotate_uid)"
fi

echo "--- ensure again after rotate: must be a no-op AT THE NEW value, never revert or re-rotate ---"
printf '%s' "should-be-ignored-$(date +%s)" | sh lab/eso/provision-source-secret.sh staging
post_second_ensure_hash="$(secret_hash "$staging_ns" "$staging_secret")"
post_second_ensure_rv="$(secret_rv "$staging_ns" "$staging_secret")"
if [ "$post_second_ensure_hash" = "$staging_rotated_hash" ] && [ "$post_second_ensure_rv" = "$post_rotate_rv" ]; then
  echo "OK: ensure after rotate is a no-op at the rotated value (hash $post_second_ensure_hash, rv $post_second_ensure_rv)"
else
  echo "FAIL: ensure after rotate changed state unexpectedly" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-provision-source-secret-idempotency: FAILED before isolation testing" >&2
  exit 1
fi

echo "--- environment isolation: staging rotate/ensure must never touch production ---"
if [ "$production_existed" -eq 1 ]; then
  production_original_value="idempotency-test-baseline-$(date +%s)-$(head -c 8 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
  printf '%s' "$production_original_value" | sh lab/eso/provision-source-secret.sh production --rotate >/dev/null
else
  production_original_value="idempotency-test-created-$(date +%s)-$(head -c 8 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
  printf '%s' "$production_original_value" | sh lab/eso/provision-source-secret.sh production >/dev/null
fi
production_uid_before="$(secret_uid "$production_ns" "$production_secret")"
production_rv_before="$(secret_rv "$production_ns" "$production_secret")"
production_hash_before="$(secret_hash "$production_ns" "$production_secret")"

staging_rotated_again_value="rotated-again-$(date +%s)-$(head -c 8 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
printf '%s' "$staging_rotated_again_value" | sh lab/eso/provision-source-secret.sh staging --rotate >/dev/null

production_uid_after="$(secret_uid "$production_ns" "$production_secret")"
production_rv_after="$(secret_rv "$production_ns" "$production_secret")"
production_hash_after="$(secret_hash "$production_ns" "$production_secret")"
if [ "$production_uid_before" = "$production_uid_after" ] && [ "$production_rv_before" = "$production_rv_after" ] && [ "$production_hash_before" = "$production_hash_after" ]; then
  echo "OK: rotating staging left production's UID/resourceVersion/hash completely unchanged"
else
  echo "FAIL: rotating staging affected production (uid: $production_uid_before -> $production_uid_after; rv: $production_rv_before -> $production_rv_after; hash: $production_hash_before -> $production_hash_after)" >&2
  fail=1
fi

staging_uid_before_prod_rotate="$(secret_uid "$staging_ns" "$staging_secret")"
staging_rv_before_prod_rotate="$(secret_rv "$staging_ns" "$staging_secret")"
staging_hash_before_prod_rotate="$(secret_hash "$staging_ns" "$staging_secret")"
production_rotated_value="prod-rotated-$(date +%s)-$(head -c 8 /dev/urandom | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
printf '%s' "$production_rotated_value" | sh lab/eso/provision-source-secret.sh production --rotate >/dev/null
staging_uid_after_prod_rotate="$(secret_uid "$staging_ns" "$staging_secret")"
staging_rv_after_prod_rotate="$(secret_rv "$staging_ns" "$staging_secret")"
staging_hash_after_prod_rotate="$(secret_hash "$staging_ns" "$staging_secret")"
if [ "$staging_uid_before_prod_rotate" = "$staging_uid_after_prod_rotate" ] && [ "$staging_rv_before_prod_rotate" = "$staging_rv_after_prod_rotate" ] && [ "$staging_hash_before_prod_rotate" = "$staging_hash_after_prod_rotate" ]; then
  echo "OK: rotating production left staging's UID/resourceVersion/hash completely unchanged"
else
  echo "FAIL: rotating production affected staging" >&2
  fail=1
fi

echo "--- closed allowlist: an arbitrary environment name must be rejected BEFORE any mutation ---"
before_ns_count="$(pkubectl get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if printf 'irrelevant' | sh lab/eso/provision-source-secret.sh not-a-real-environment 2>/tmp/.psi-err.$$; then
  echo "FAIL: an arbitrary environment name was accepted" >&2
  fail=1
else
  echo "OK: arbitrary environment name 'not-a-real-environment' correctly rejected"
fi
rm -f /tmp/.psi-err.$$
after_ns_count="$(pkubectl get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$before_ns_count" = "$after_ns_count" ]; then
  echo "OK: zero mutation from the rejected environment name (namespace count unchanged: $after_ns_count)"
else
  echo "FAIL: namespace count changed despite the rejected environment name" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "test-provision-source-secret-idempotency: PART 1 FAILED" >&2
  exit 1
fi
echo "=== PART 1: OK ==="

echo "=== PART 2: global_kubeconfig_fingerprint / assert_kubeconfig_paths_distinct (Gap 5) ==="

fixture_root="$(mktemp -d)"
cleanup_fixtures() { rm -rf "$fixture_root"; }
trap 'cleanup_fixtures; restore_state' EXIT INT TERM

fixture_a="${fixture_root}/inherited-kubeconfig.yaml"
fixture_b="${fixture_root}/global-kubeconfig.yaml"
fixture_spaces_dir="${fixture_root}/dir with spaces"
mkdir -p "$fixture_spaces_dir"
fixture_spaces="${fixture_spaces_dir}/kubeconfig.yaml"

write_fixture() {
  # $1=path $2=context-name - no credentials, no clusters/users content.
  cat > "$1" <<EOF
apiVersion: v1
kind: Config
current-context: $2
clusters: []
contexts:
- name: $2
  context: {}
users: []
EOF
}

write_fixture "$fixture_a" "fixture-a-inherited-context"
write_fixture "$fixture_b" "fixture-b-global-context"
write_fixture "$fixture_spaces" "fixture-spaces-context"

echo "--- helper measures the EXPLICIT path, never an inherited KUBECONFIG ---"
KUBECONFIG="$fixture_a" sh -c '
  . scripts/lab/_lib.sh
  require_repo_root
  global_kubeconfig_fingerprint "'"$fixture_b"'"
' > "${fixture_root}/result_b_while_a_inherited.txt"
read -r sha_b ctx_b < "${fixture_root}/result_b_while_a_inherited.txt"
if [ "$ctx_b" = "fixture-b-global-context" ]; then
  echo "OK: helper measured fixture B's context ($ctx_b) while KUBECONFIG env pointed at fixture A - inherited KUBECONFIG ignored"
else
  echo "FAIL: helper did not measure the explicit path correctly (got context '$ctx_b')" >&2
  fail=1
fi

echo "--- ABSENT is stable and never crashes ---"
absent_result="$(global_kubeconfig_fingerprint "${fixture_root}/does-not-exist.yaml")"
if [ "$absent_result" = "ABSENT ABSENT" ]; then
  echo "OK: absent kubeconfig path reports a stable 'ABSENT ABSENT'"
else
  echo "FAIL: absent path did not report the expected stable state (got '$absent_result')" >&2
  fail=1
fi

echo "--- changing fixture A never changes fixture B's fingerprint ---"
sha_b_before="$sha_b"
write_fixture "$fixture_a" "fixture-a-CHANGED-context"
sha_b_after="$(global_kubeconfig_fingerprint "$fixture_b" | awk '{print $1}')"
if [ "$sha_b_before" = "$sha_b_after" ]; then
  echo "OK: modifying fixture A did not change fixture B's fingerprint (still $sha_b_after)"
else
  echo "FAIL: fixture B's fingerprint changed after only fixture A was modified" >&2
  fail=1
fi

echo "--- changing fixture B DOES change its own fingerprint ---"
write_fixture "$fixture_b" "fixture-b-CHANGED-context"
sha_b_changed="$(global_kubeconfig_fingerprint "$fixture_b" | awk '{print $1}')"
if [ "$sha_b_changed" != "$sha_b_after" ]; then
  echo "OK: modifying fixture B changed its own fingerprint ($sha_b_after -> $sha_b_changed)"
else
  echo "FAIL: fixture B's fingerprint did not change after it was actually modified" >&2
  fail=1
fi

echo "--- a path containing spaces is handled correctly ---"
spaces_result="$(global_kubeconfig_fingerprint "$fixture_spaces")"
case "$spaces_result" in
  *"fixture-spaces-context") echo "OK: path-with-spaces fixture measured correctly ($spaces_result)" ;;
  *) echo "FAIL: path-with-spaces fixture not measured correctly (got '$spaces_result')" >&2; fail=1 ;;
esac

echo "--- assert_kubeconfig_paths_distinct: distinct paths pass, identical paths fail ---"
if PROJECT_KUBECONFIG="$fixture_a" assert_kubeconfig_paths_distinct "$fixture_b"; then
  echo "OK: distinct fixture paths pass the assertion"
else
  echo "FAIL: distinct fixture paths incorrectly failed the assertion" >&2
  fail=1
fi
if PROJECT_KUBECONFIG="$fixture_a" assert_kubeconfig_paths_distinct "$fixture_a"; then
  echo "FAIL: identical fixture paths incorrectly passed the assertion" >&2
  fail=1
else
  echo "OK: identical fixture paths correctly fail the assertion"
fi

echo "--- no fixture ever touched the real \$HOME ---"
case "$fixture_root" in
  "$HOME"*) echo "FAIL: fixture root is under \$HOME - this must never happen" >&2; fail=1 ;;
  *) echo "OK: all fixtures lived under a mktemp -d path outside \$HOME ($fixture_root)" ;;
esac
if [ -f "$HOME/.kube/config" ]; then
  real_home_sha_before_check="$(shasum -a 256 "$HOME/.kube/config" | awk '{print $1}')"
  real_home_sha_after_check="$(shasum -a 256 "$HOME/.kube/config" | awk '{print $1}')"
  if [ "$real_home_sha_before_check" = "$real_home_sha_after_check" ]; then
    echo "OK: the real \$HOME/.kube/config (if any) is unchanged by this test's fixtures"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "test-provision-source-secret-idempotency: PART 2 FAILED" >&2
  exit 1
fi
echo "=== PART 2: OK ==="

echo "test-provision-source-secret-idempotency: OK"
