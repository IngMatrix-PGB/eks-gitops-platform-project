#!/bin/sh
# Phase 5.1c-1: offline end-to-end test of image promotion. Copies the
# files promotion touches into a scratch git repository, then drives
# scripts/promote/promote.sh and scripts/validate/check-promotion.sh with
# fake cosign/docker binaries (no network, no registry, no signature).
# Proves the order dev <- main, uat <- dev, prod <- uat, the refusals,
# that only the target environment's two overlays and one ledger row
# change, and that check-promotion catches hand edits that skip the flow.
# Backs `make promote-test` (in `make validate`).
set -eu

[ -f scripts/promote/promote.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
here="$(pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

work="$root/repo"
mkdir -p "$work"
for f in scripts/image/image.sh scripts/promote/_lib.sh scripts/promote/promote.sh \
         scripts/validate/check-promotion.sh scripts/lab/tool-versions.txt \
         charts/standard-workload/values-dev.yaml charts/standard-workload/values-dev-aws.yaml \
         charts/standard-workload/values-uat.yaml charts/standard-workload/values-uat-aws.yaml \
         charts/standard-workload/values-prod.yaml charts/standard-workload/values-prod-aws.yaml \
         gitops/promotions/smoke.tsv; do
  mkdir -p "$work/$(dirname "$f")"; cp "$f" "$work/$f"
done
cd "$work"
git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm base
base="$(git rev-parse HEAD)"

repo="ghcr.io/ingmatrix-pgb/eks-gitops-platform-smoke"
hex() { printf "$1%.0s" $(seq 1 64); }
d1="sha256:$(hex 1)"; d2="sha256:$(hex 2)"

mkdir -p "$root/bin"
cat > "$root/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
  "buildx imagetools inspect"*) printf 'linux/amd64 sha256:%064d\nlinux/arm64 sha256:%064d\n' 7 8 ;;
  *) exit 97 ;;
esac
EOF
cat > "$root/bin/cosign" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_COSIGN_LOG"
if [ -n "${FAKE_UNSIGNED:-}" ]; then
  case "$*" in *"$FAKE_UNSIGNED"*) echo "no matching signatures" >&2; exit 1 ;; esac
fi
exit 0
EOF
chmod +x "$root/bin/docker" "$root/bin/cosign"
: > "$root/cosign.log"

promote() {
  env PATH="$root/bin:$PATH" COSIGN_BIN="$root/bin/cosign" FAKE_COSIGN_LOG="$root/cosign.log" \
    FAKE_UNSIGNED="${UNSIGNED:-}" ENV="$1" DIGEST="${2:-}" sh scripts/promote/promote.sh > "$root/out" 2>&1
}
check() { PROMOTION_BASE_REF="$base" bash scripts/validate/check-promotion.sh > "$root/check" 2>&1; }
ref_of() { . scripts/promote/_lib.sh; overlay_image_ref "charts/standard-workload/values-$1.yaml"; }
rows() { grep -cvE '^[[:space:]]*(#|$)' gitops/promotions/smoke.tsv || true; }
changed() { git status --porcelain | awk '{print $2}' | sort | tr '\n' ' '; }

# --- baseline: podinfo everywhere, empty ledger ---
check && ok "baseline passes check-promotion" || { bad "baseline fails: $(cat "$root/check")"; }

# --- refusals before anything is promoted ---
expect_refused() {
  desc="$1" reason="$2"
  if [ "$rc" -eq 0 ]; then bad "accepted: $desc"
  elif ! grep -q -- "$reason" "$root/out"; then bad "$desc: refused for the wrong reason: $(cat "$root/out")"
  elif [ -n "$(changed)" ]; then bad "$desc: refused but changed $(changed)"
  else ok "refused, nothing changed: $desc"; fi
}
rc=0; promote uat || rc=$?; expect_refused "uat while dev still runs podinfo" "promote dev first"
rc=0; promote dev || rc=$?; expect_refused "dev without DIGEST" "dev needs DIGEST"
rc=0; promote qa "$d1" || rc=$?; expect_refused "unknown environment" "ENV must be one of"
rc=0; promote dev "sha256:abc" || rc=$?; expect_refused "malformed digest" "DIGEST must be"
# A variable assignment before a shell function call persists after it
# in POSIX sh, so the unsigned case runs in a subshell.
rc=0; ( UNSIGNED="$d1" promote dev "$d1" ) || rc=$?; expect_refused "an unsigned digest into dev" "did not verify"

# --- dev <- main ---
if promote dev "$d1"; then
  if [ "$(ref_of dev)" = "$repo@$d1" ] && [ "$(ref_of dev-aws)" = "$repo@$d1" ] \
     && [ "$(changed)" = "charts/standard-workload/values-dev-aws.yaml charts/standard-workload/values-dev.yaml gitops/promotions/smoke.tsv " ] \
     && [ "$(rows)" = "1" ] && grep -q "verify --certificate-identity" "$root/cosign.log"; then
    ok "dev promoted from main after verify: only dev's two overlays + one ledger row changed"
  else
    bad "dev promotion changed the wrong things: $(changed) rows=$(rows)"
  fi
else
  bad "dev promotion failed: $(cat "$root/out")"
fi
check && ok "check-promotion passes after dev" || bad "check-promotion fails after dev: $(cat "$root/check")"
promote dev "$d1" && grep -q 'nothing to do' "$root/out" && [ "$(rows)" = "1" ] \
  && ok "promoting dev to the same digest again is a no-op (no duplicate row)" || bad "re-promotion not a no-op: $(cat "$root/out")"

rc=0; promote prod || rc=$?
[ "$rc" -ne 0 ] && grep -q 'promote uat first' "$root/out" && ok "refused: prod before uat" || bad "prod before uat was not refused: $(cat "$root/out")"
rc=0; promote uat "$d2" || rc=$?
[ "$rc" -ne 0 ] && grep -q "may only take dev's image" "$root/out" && ok "refused: uat with a digest dev does not run" || bad "uat with a foreign digest was not refused"

# --- uat <- dev, prod <- uat ---
promote uat && [ "$(ref_of uat)" = "$repo@$d1" ] && [ "$(ref_of uat-aws)" = "$repo@$d1" ] \
  && ok "uat promoted from dev" || bad "uat promotion failed: $(cat "$root/out")"
promote prod && [ "$(ref_of prod)" = "$repo@$d1" ] && [ "$(ref_of prod-aws)" = "$repo@$d1" ] && [ "$(rows)" = "3" ] \
  && ok "prod promoted from uat (3 ledger rows)" || bad "prod promotion failed: $(cat "$root/out")"
check && ok "check-promotion passes after dev -> uat -> prod" || bad "check-promotion fails after the full flow: $(cat "$root/check")"
git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm promoted
base="$(git rev-parse HEAD)"

# --- hand edits that skip the flow are caught ---
mutate_check() {
  desc="$1" reason="$2"
  if check; then bad "check-promotion accepted: $desc"
  elif grep -q -- "$reason" "$root/check"; then ok "check-promotion caught: $desc"
  else bad "$desc: caught for the wrong reason: $(cat "$root/check")"; fi
  git checkout -q -- . && git clean -qfd
}
sed -i.bak "s/$d1/$d2/" charts/standard-workload/values-prod.yaml charts/standard-workload/values-prod-aws.yaml && rm -f charts/standard-workload/*.bak
mutate_check "prod set by hand to a digest never promoted" "has no promotion of it into prod"
sed -i.bak "s/$d1/$d2/" charts/standard-workload/values-prod.yaml charts/standard-workload/values-prod-aws.yaml && rm -f charts/standard-workload/*.bak
printf '2099-01-01\tprod\t%s@%s\tuat\n' "$repo" "$d2" >> gitops/promotions/smoke.tsv
mutate_check "a forged prod row for a digest uat never had" "which uat never had before it"
sed -i.bak "s/$d1/$d2/" charts/standard-workload/values-dev-aws.yaml && rm -f charts/standard-workload/*.bak
mutate_check "dev and dev-aws disagree" "must hold the same image"
sed -i.bak '/	uat	/d' gitops/promotions/smoke.tsv && rm -f gitops/promotions/*.bak
mutate_check "a ledger row removed" "append-only"
awk 'BEGIN{FS=OFS="\t"} !/^#/ && !done {$1="2000-01-01"; done=1} {print}' gitops/promotions/smoke.tsv > "$root/l" && cat "$root/l" > gitops/promotions/smoke.tsv
mutate_check "an existing ledger row edited (order still valid)" "append-only"
printf '2099-01-01\tuat\t%s@%s\tmain\n' "$repo" "$d1" >> gitops/promotions/smoke.tsv
mutate_check "uat recorded as promoted straight from main" "may only be promoted from 'dev'"
awk '/^image:/{skip=1; next} skip && /^  /{next} {skip=0; print}' charts/standard-workload/values-uat.yaml > "$root/u" && cat "$root/u" > charts/standard-workload/values-uat.yaml
mutate_check "an overlay without its own image block" "needs its own image block"

cd "$here"
if [ "$fail" -ne 0 ]; then echo "promote-test: FAILED"; exit 1; fi
echo "promote-test: OK"
