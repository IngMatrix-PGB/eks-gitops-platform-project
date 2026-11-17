#!/usr/bin/env bash
# Phase 5.2b (ADR-0019): static analysis of the Terraform code with the
# pinned trivy (scripts/lab/tool-versions.txt). Backs `make tf-static`.
#
# What it scans: a scratch copy of the files Git tracks under terraform/,
# so a local .terraform/ cache, state or example directory never changes
# the result. trivy resolves the pinned registry modules itself, so the
# upstream EKS and VPC modules are evaluated with this repository's inputs.
#
# Which rules: the checks embedded in the pinned trivy binary
# (--skip-check-update with an empty cache directory). The result changes
# only when tool-versions.txt changes, never because a new rule bundle was
# published.
#
# Gate: any HIGH or CRITICAL finding fails, unless terraform/.trivyignore.yaml
# accepts it for that exact file, with an expiry date and a statement. An
# accepted entry that no longer matches a finding also fails, so the file
# never keeps stale exceptions.
#
# Output: .tools/out/terraform/trivy-config.json (every severity) and a
# table of the MEDIUM/LOW findings, which are reported, not gated.
set -euo pipefail

TRIVY_BIN=".tools/bin/trivy"
TF_STATIC_SEVERITY="HIGH,CRITICAL"
TF_IGNORE_FILE="terraform/.trivyignore.yaml"
OUT_DIR=".tools/out/terraform"
today="${TF_STATIC_TODAY:-$(date -u +%Y-%m-%d)}"

die() { echo "tf-static: $*" >&2; exit 1; }
need() { [ -x "$1" ] || command -v "$1" >/dev/null 2>&1 || die "$1 not found (run make tools-install)"; }

need "$TRIVY_BIN"
need jq
need git
[ -f "$TF_IGNORE_FILE" ] || die "$TF_IGNORE_FILE missing (an empty 'misconfigurations: []' is fine)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

# Scratch copy of the tracked Terraform files only.
mkdir -p "$work/src"
while IFS= read -r -d '' f; do
  mkdir -p "$work/src/$(dirname "$f")"
  cp "$f" "$work/src/$f"
done < <(git ls-files -z terraform)
mkdir -p "$OUT_DIR"
repo="$(pwd)"

trivy_config() {
  # $@ = extra flags. Fresh cache directory: embedded checks only.
  (cd "$work/src" && "$repo/$TRIVY_BIN" config --cache-dir "$work/cache" --quiet \
    --skip-check-update --misconfig-scanners terraform "$@" terraform)
}

# 1. Every accepted finding is well formed and not expired. The layout is
#    fixed: id, one or more exact paths, expired_at, statement.
entries="$work/entries.tsv"
awk -v today="$today" '
  function flush() {
    if (id == "") return
    if (np == 0 || xd == "" || st == "") { print "BAD\t" id "\tneeds paths, expired_at and statement"; bad = 1 }
    else if (xd < today) { print "BAD\t" id "\texpired on " xd; bad = 1 }
    else for (i = 1; i <= np; i++) print "OK\t" id "\t" p[i]
    id = ""; np = 0; xd = ""; st = ""
  }
  /^[[:space:]]*(#|$)/ { next }
  /^misconfigurations:/ { next }
  /^  - id: [A-Z]+-[0-9]+$/ { flush(); id = $3; next }
  /^    paths:$/ { next }
  /^      - "[^"*?]+"$/ { v = $2; gsub(/"/, "", v); p[++np] = v; next }
  /^    expired_at: [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]$/ { xd = $2; next }
  /^    statement: ".*"$/ { if (length($0) >= 37) { st = $0; next } }
  { print "BAD\t-\tunexpected line: " $0; bad = 1 }
  END { flush() }
' "$TF_IGNORE_FILE" > "$entries"
if grep -q '^BAD' "$entries"; then
  grep '^BAD' "$entries" | cut -f2- | sed "s#^#$TF_IGNORE_FILE: #" >&2
  die "$TF_IGNORE_FILE is not valid (layout: id, exact paths, expired_at, statement of 20+ chars)"
fi

# 2. Full scan without any exception: the record, and the stale check.
trivy_config --format json --output "$repo/$OUT_DIR/trivy-config.json"
jq -r '.Results[]? | .Target as $t | .Misconfigurations[]?
       | select(.Status == "FAIL" and (.Severity == "HIGH" or .Severity == "CRITICAL"))
       | "\(.ID)\t\($t)"' "$OUT_DIR/trivy-config.json" | sort -u > "$work/gated.tsv"
stale=0
while IFS=$'\t' read -r _ id path; do
  grep -qxF "$id	$path" "$work/gated.tsv" || { echo "tf-static: stale exception $id for $path (no such finding any more) - remove it from $TF_IGNORE_FILE" >&2; stale=1; }
done < <(grep '^OK' "$entries")
[ "$stale" -eq 0 ] || die "$TF_IGNORE_FILE holds stale exceptions"

# 3. Report-only: MEDIUM and LOW.
echo "tf-static: MEDIUM/LOW findings (reported, not gated):"
jq -r '.Results[]? | .Target as $t | .Misconfigurations[]?
       | select(.Status == "FAIL" and (.Severity == "MEDIUM" or .Severity == "LOW"))
       | "  \(.Severity)\t\(.ID)\t\($t):\(.CauseMetadata.StartLine)\t\(.Title)"' "$OUT_DIR/trivy-config.json" | sort

# 4. The gate.
echo "tf-static: trivy config terraform/ (fail on $TF_STATIC_SEVERITY, exceptions from $TF_IGNORE_FILE) ..."
cp "$TF_IGNORE_FILE" "$work/ignore.yaml"
trivy_config --exit-code 1 --severity "$TF_STATIC_SEVERITY" --ignorefile "$work/ignore.yaml"
echo "tf-static: OK ($(grep -c '^OK' "$entries" || true) accepted finding(s), each dated and scoped to one file)"
