#!/bin/sh
# Regression tests for scripts/docs/release.sh's guards (Phase 7c): the
# script, unmodified, in a throwaway Git repository with a local bare
# "origin" and a fake `gh` on PATH that only records its arguments. No
# network, no GitHub, nothing outside one mktemp -d root. Backs
# `make docs-release-regression`.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/docs/release.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0; n=0
g() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }

mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'EOF'
#!/bin/sh
echo "$*" > "$FAKE_GH_LOG"
EOF
chmod +x "$root/bin/gh"

setup() { # fresh repo on main, pushed to a bare origin, with a valid build
  fx="$1"
  git init -q --bare "$fx/origin.git"
  git init -q -b main "$fx/repo"
  cd "$fx/repo"
  mkdir -p docs/architecture/diagrams scripts/gitops dist/build
  printf '| Version | 1.2.3 |\n' > docs/architecture/technical-architecture.md
  printf 'GITOPS_OWNER_REPO="example/repo"\n' > scripts/gitops/_lib.sh
  printf '<svg/>\n' > docs/architecture/diagrams/a.svg
  printf '/dist/\n' > .gitignore
  g add -A && g commit -q -m init
  g remote add origin "$fx/origin.git" && g push -q origin main 2>/dev/null
  printf 'docx\n' > dist/technical-architecture-1.2.3.docx
  echo "$(git rev-parse HEAD) docs-v1.2.3" > dist/build/stamp
}
run_case() { # $1=description $2=accept|reject $3=mutation function $4=CONFIRM value
  n=$((n + 1)); fx="$root/case$n"; mkdir -p "$fx"
  ( setup "$fx" ) >/dev/null 2>&1
  ( cd "$fx/repo" && "$3" ) >/dev/null 2>&1
  log="$fx/gh.log"
  if (cd "$fx/repo" && PATH="$root/bin:$PATH" FAKE_GH_LOG="$log" CONFIRM="$4" sh "$script" > "$fx.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = accept ] && ! grep -q '^release create docs-v1.2.3 ' "$log" 2>/dev/null; then got="accept-without-gh"; fi
  if [ "$got" = reject ] && [ -f "$log" ]; then got="reject-after-gh"; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$fx.out" >&2; fail=$((fail + 1)); fi
}

none() { :; }
run_case "everything in order publishes through gh" accept none yes
run_case "without CONFIRM=yes it refuses before gh" reject none ""
run_case "CONFIRM other than yes refuses" reject none "y"
branch() { g checkout -q -b other; }
run_case "a branch other than main refuses" reject branch yes
dirty() { echo x >> scripts/gitops/_lib.sh; }
run_case "a dirty working tree refuses" reject dirty yes
ahead() { echo y > extra && g add extra && g commit -q -m ahead && echo "$(git rev-parse HEAD) docs-v1.2.3" > dist/build/stamp; }
run_case "main ahead of origin/main refuses" reject ahead yes
tagged() { g tag docs-v1.2.3; }
run_case "an existing local tag refuses" reject tagged yes
remote_tag() { g tag docs-v1.2.3 && g push -q origin docs-v1.2.3 && g tag -d docs-v1.2.3; }
run_case "an existing tag on origin refuses" reject remote_tag yes
no_docx() { rm dist/technical-architecture-1.2.3.docx; }
run_case "a missing DOCX refuses" reject no_docx yes
stale() { echo "dirty docs-v1.2.3" > dist/build/stamp; }
run_case "a DOCX built from a dirty tree refuses" reject stale yes
other_ref() { echo "$(git rev-parse HEAD) main" > dist/build/stamp; }
run_case "a DOCX linking to another ref refuses" reject other_ref yes

echo ""
echo "test-release-guards: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-release-guards: FAILED"; exit 1; }
echo "test-release-guards: OK"
