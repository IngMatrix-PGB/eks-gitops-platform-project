#!/usr/bin/env bash
# Verifies that the README, the TAD and the ADR files tell the same
# story (Phase 7a):
#
#  1. ADRs: every docs/adr/NNNN-*.md is listed exactly once in the TAD's
#     "Architecture Decisions" table and in README's ADR table, with the
#     same title (a trailing parenthetical and letter case ignored) and a
#     status that starts with the ADR's own "**Status:**" value; neither
#     table lists more ADRs than exist.
#  2. Phases: every row of README's "Current status" tables (first cell
#     the phase, last cell the status) names a phase that exists in the
#     TAD's "Delivery Roadmap" with the same status word, and every
#     top-level "Phase N" of the roadmap has a README row. Status words,
#     earliest one in the text wins: "not started", "in progress",
#     "planned", "implemented"/"complete" (the last two are the same).
#  3. Runbooks: every docs/runbooks/*.md is linked from README or the TAD.
#
# Limitation: this compares titles and status words, not prose. Whether
# a status is true is still reviewed by hand with each pull request.
set -uo pipefail

readme="README.md"
tad="docs/architecture/technical-architecture.md"
fail=0
for f in "$readme" "$tad"; do
  [ -f "$f" ] || { echo "FAIL: $f not found"; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

# section NAME FILE: the lines of the "## NAME" section (up to the next H2).
section() {
  awk -v h="## $1" '$0==h{on=1; next} on && /^## /{exit} on' "$2"
}

norm_title() { # lowercase, trailing "(...)" removed, spaces trimmed
  sed -E 's/[[:space:]]*\([^()]*\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]'
}

# --- 1. ADRs -----------------------------------------------------------
section "Architecture Decisions" "$tad" > "$work/tad-adr"
section "Architecture Decision Records" "$readme" > "$work/readme-adr"
adr_count=0
for f in docs/adr/[0-9][0-9][0-9][0-9]-*.md; do
  [ -f "$f" ] || continue
  adr_count=$((adr_count + 1))
  base="$(basename "$f")"
  num="${base%%-*}"
  title="$(head -n1 "$f" | sed -E "s/^# ADR-$num: //" | norm_title)"
  status="$(grep -m1 -E '^\*\*Status:\*\* ' "$f" | sed -E 's/^\*\*Status:\*\* //; s/[[:space:]]*$//')"
  for pair in "TAD|$work/tad-adr|../adr/$base" "README|$work/readme-adr|docs/adr/$base"; do
    doc="${pair%%|*}"; rest="${pair#*|}"; tbl="${rest%%|*}"; link="${rest#*|}"
    rows="$(grep -F "]($link)" "$tbl" | grep -E '^\|' || true)"
    nrows="$(printf '%s' "$rows" | grep -c '^|' || true)"
    if [ "$nrows" -ne 1 ]; then
      echo "FAIL: $doc lists ADR-$num ($base) $nrows times in its ADR table (expected once)"
      fail=1; continue
    fi
    cell_title="$(printf '%s\n' "$rows" | awk -F'|' '{print $3}' | norm_title)"
    cell_status="$(printf '%s\n' "$rows" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4}')"
    if [ "$cell_title" != "$title" ]; then
      echo "FAIL: $doc's title for ADR-$num is '$cell_title', the ADR says '$title'"
      fail=1
    fi
    case "$cell_status" in
      "$status"*) ;;
      *) echo "FAIL: $doc's status for ADR-$num is '$cell_status', the ADR says '$status'"; fail=1 ;;
    esac
  done
done
for pair in "TAD|$work/tad-adr|\]\(\.\./adr/[0-9]{4}-" "README|$work/readme-adr|\]\(docs/adr/[0-9]{4}-"; do
  doc="${pair%%|*}"; rest="${pair#*|}"; tbl="${rest%%|*}"; re="${rest#*|}"
  listed="$(grep -E '^\|' "$tbl" | grep -cE "$re" || true)"
  if [ "$listed" -ne "$adr_count" ]; then
    echo "FAIL: $doc's ADR table has $listed rows; docs/adr has $adr_count ADRs"
    fail=1
  fi
done

# --- 2. Phases ---------------------------------------------------------
# status_word TEXT -> done | in progress | planned | not started | ""
status_word() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | awk '
    { best=0; w="";
      n=split("not started|in progress|planned|implemented|complete", k, "|");
      for (i=1; i<=n; i++) { p=index($0, k[i]); if (p>0 && (best==0 || p<best)) { best=p; w=k[i] } }
      if (w=="implemented" || w=="complete") w="done";
      print w }'
}

# TAD roadmap: "<id>|<status text>" per bullet "- **[Phase ]ID — Title:** status".
section "Delivery Roadmap" "$tad" \
  | sed -nE 's/^[[:space:]]*- \*\*(Phase )?([0-9][^ ]*) — [^*]*:\*\*[[:space:]]*(.*)$/\2|\3/p' > "$work/tad-phases"
# README "Current status" rows: "<id>|<last cell>"; "Phase N" becomes "N".
section "Current status" "$readme" \
  | awk -F'|' '/^\| *(Phase )?[0-9]/{id=$2; st=$(NF-1); gsub(/^[ \t]+|[ \t]+$/, "", id); sub(/^Phase /, "", id); gsub(/^[ \t]+|[ \t]+$/, "", st); print id "|" st}' > "$work/readme-phases"

if [ ! -s "$work/tad-phases" ]; then echo "FAIL: no phase found in the TAD's Delivery Roadmap"; fail=1; fi
if [ ! -s "$work/readme-phases" ]; then echo "FAIL: no phase row found in README's Current status"; fail=1; fi

while IFS='|' read -r id st; do
  [ -n "$id" ] || continue
  tad_line="$(awk -F'|' -v id="$id" '$1==id' "$work/tad-phases")"
  tad_n="$(printf '%s' "$tad_line" | grep -c . || true)"
  if [ "$tad_n" -ne 1 ]; then
    echo "FAIL: README phase '$id' appears $tad_n times in the TAD's Delivery Roadmap (expected once)"
    fail=1; continue
  fi
  rw="$(status_word "$st")"
  tw="$(status_word "${tad_line#*|}")"
  if [ -z "$rw" ] || [ -z "$tw" ]; then
    echo "FAIL: phase '$id' has no recognized status word (README '${rw:-none}', TAD '${tw:-none}')"
    fail=1
  elif [ "$rw" != "$tw" ]; then
    echo "FAIL: phase '$id' is '$rw' in README but '$tw' in the TAD's Delivery Roadmap"
    fail=1
  fi
done < "$work/readme-phases"

section "Delivery Roadmap" "$tad" | sed -nE 's/^- \*\*Phase ([0-9]+) — .*/\1/p' | while read -r top; do
  if ! awk -F'|' -v id="$top" '$1==id{f=1} END{exit !f}' "$work/readme-phases"; then
    echo "FAIL: TAD roadmap Phase $top has no row in README's Current status"
    echo x >> "$work/top-missing"
  fi
done
[ -f "$work/top-missing" ] && fail=1

# --- 3. Runbooks -------------------------------------------------------
for f in docs/runbooks/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  if ! grep -qF "runbooks/$base" "$readme" "$tad"; then
    echo "FAIL: runbook $f is linked from neither README nor the TAD"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "check-docs-consistency: FAILED"
  exit 1
fi
echo "check-docs-consistency: OK ($adr_count ADRs, $(wc -l < "$work/readme-phases" | tr -d ' ') README phase rows, $(ls docs/runbooks/*.md | wc -l | tr -d ' ') runbooks)"
