#!/bin/sh
# Regression tests for bk_store_ensure_user (scripts/backup/_lib.sh), the
# fix from Phase 7d: on a fresh lab the store's change-bucket-owner
# sometimes answered InternalError, and backup-install still reported the
# bucket as owned. A fake `docker` on PATH plays the store: it fails the
# owner change a set number of times and lists buckets from a state file.
# No Docker, no network, nothing outside one mktemp -d root. Backs
# `make backup-store-regression`.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0

mkdir -p "$root/bin"
cat > "$root/bin/docker" <<'EOF'
#!/bin/sh
# fake: docker exec --env-file F CONTAINER versitygw admin <cmd> [--bucket B --owner O]
shift 4; shift 2
cmd="$1"; shift
case "$cmd" in
  change-bucket-owner)
    n="$(cat "$FAKE/fails" 2>/dev/null || echo 0)"
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FAKE/fails"; echo "api error InternalError" >&2; exit 1; fi
    [ -f "$FAKE/wrong-owner" ] && { echo "$2 someone-else" >> "$FAKE/owners"; exit 0; }
    echo "$2 $4" >> "$FAKE/owners" ;;
  list-buckets)
    printf 'Bucket Owner\n------- ----\n'; cat "$FAKE/owners" 2>/dev/null || true ;;
esac
EOF
chmod +x "$root/bin/docker"

# $1=description $2=expected stdout ("" = must fail) $3=owner-change failures $4=wrong owner (yes|no)
run_case() {
  fx="$root/case$((pass + fail + 1))"; mkdir -p "$fx/.local/backups/iam" "$fx/fake"; ln -s "$here/scripts" "$fx/scripts"
  echo "$3" > "$fx/fake/fails"
  [ "$4" = yes ] && touch "$fx/fake/wrong-owner"
  if got="$(cd "$fx" && PATH="$root/bin:$PATH" FAKE="$fx/fake" BK_OWNER_TRIES=4 \
      sh -c ". '$here/scripts/backup/_lib.sh'; bk_store_ensure_user velero-dev velero-dev" 2>"$fx/err")"; then :; else got=""; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected '${2:-failure}', got '${got:-failure}')" >&2; sed 's/^/    /' "$fx/err" >&2; fail=$((fail + 1)); fi
}

run_case "a new user whose owner change works at once is created" created 0 no
run_case "two transient InternalErrors are retried, then created" created 2 no
run_case "an owner change that never works fails, printing nothing" "" 9 no
run_case "a change that 'works' but leaves another owner fails" "" 0 yes

# An existing user is kept, and the bucket's owner is still checked.
fx="$root/kept"; mkdir -p "$fx/.local/backups/iam" "$fx/fake"; ln -s "$here/scripts" "$fx/scripts"
echo 0 > "$fx/fake/fails"
if got="$(cd "$fx" && PATH="$root/bin:$PATH" FAKE="$fx/fake" BK_OWNER_TRIES=4 \
    sh -c ". '$here/scripts/backup/_lib.sh'; bk_store_ensure_user velero-dev velero-dev >/dev/null; bk_store_ensure_user velero-dev velero-dev")" \
    && [ "$got" = kept ]; then echo "OK: a second run keeps the user"; pass=$((pass + 1))
else echo "FAIL: a second run keeps the user (got '${got:-failure}')" >&2; fail=$((fail + 1)); fi

echo ""
echo "test-store-ensure-user: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-store-ensure-user: FAILED"; exit 1; }
echo "test-store-ensure-user: OK"
