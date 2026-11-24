#!/bin/sh
# Builds the DOCX export of the Technical Architecture Document (Phase 7c,
# local only: CI needs neither pandoc nor draw.io).
#
#   dist/technical-architecture-<version>.docx
#
# Content: the TAD (its H1 becomes the document title, its H2 sections
# the numbered chapters), then an appendix with every ADR's status and
# its "Decision" section. Mermaid blocks become a pointer to the draw.io
# figures, which are embedded as PNG; relative links become GitHub URLs
# at DOCX_REF (default: the release tag docs-v<version>).
#
# Then it checks the result: pandoc reads the DOCX back to text, and every
# TAD section and ADR must be there, no Mermaid source may remain, the four
# figures must be embedded, and the text must pass the same generic
# patterns as check-forbidden-terms plus the optional local denylist.
set -eu

tad="docs/architecture/technical-architecture.md"
diagrams="docs/architecture/diagrams"
out_dir="dist"
build="$out_dir/build"

command -v pandoc >/dev/null 2>&1 || { echo "FAIL: pandoc not found" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "FAIL: unzip not found" >&2; exit 1; }
drawio="${DRAWIO:-}"
if [ -z "$drawio" ]; then
  if command -v drawio >/dev/null 2>&1; then drawio="drawio"
  elif [ -x "/Applications/draw.io.app/Contents/MacOS/draw.io" ]; then drawio="/Applications/draw.io.app/Contents/MacOS/draw.io"
  else echo "FAIL: draw.io desktop CLI not found (install draw.io or set DRAWIO=<path>)" >&2; exit 1
  fi
fi

version="$(sed -nE 's/^\| Version \| ([0-9]+\.[0-9]+\.[0-9]+) \|$/\1/p' "$tad")"
[ -n "$version" ] || { echo "FAIL: no '| Version | x.y.z |' row in $tad" >&2; exit 1; }
owner_repo="$(sed -nE 's/^GITOPS_OWNER_REPO="([^"]+)"$/\1/p' scripts/gitops/_lib.sh)"
[ -n "$owner_repo" ] || { echo "FAIL: GITOPS_OWNER_REPO not found in scripts/gitops/_lib.sh" >&2; exit 1; }
ref="${DOCX_REF:-docs-v$version}"
docx="$out_dir/technical-architecture-$version.docx"

rm -rf "$build"
mkdir -p "$build/png"

# 1. Figures: PNG exports of the draw.io sources (Word renders PNG everywhere).
n_fig=0
for src in "$diagrams"/*.drawio; do
  [ -f "$src" ] || continue
  name="$(basename "$src" .drawio)"
  "$drawio" --export --format png --scale 2 --border 10 --theme light \
    --output "$build/png/$name.png" "$src" >/dev/null 2>&1 \
    || { echo "FAIL: draw.io could not export $src" >&2; exit 1; }
  n_fig=$((n_fig + 1))
done
[ "$n_fig" -gt 0 ] || { echo "FAIL: no draw.io source under $diagrams" >&2; exit 1; }

# 2. Body: the TAD without its H1 (the title comes from metadata).
title="$(head -n1 "$tad" | sed -E 's/^# //')"
tail -n +2 "$tad" > "$build/tad.md"

# 3. Appendix: each ADR's status and Decision section, one heading level
#    below the appendix (after the global shift of -1).
{
  echo "## Appendix: Architecture Decision Records"
  echo
  echo "Each ADR's status and its Decision section, as of this version. The full"
  echo "records (context, alternatives, consequences) are in \`docs/adr/\`."
  echo
  for f in docs/adr/[0-9][0-9][0-9][0-9]-*.md; do
    adr_title="$(head -n1 "$f" | sed -E 's/^# //')"
    status="$(grep -m1 -E '^\*\*Status:\*\* ' "$f" | sed -E 's/^\*\*Status:\*\* //')"
    echo "### $adr_title"
    echo
    echo "**Status:** $status"
    echo
    awk '$0=="## Decision"{on=1; next} on && /^## /{exit} on{ if ($0 ~ /^#+ /) $0 = "#" $0; print }' "$f"
    echo
  done
} > "$build/adr-appendix.md"

# 4. DOCX.
DOCX_REPO_URL="https://github.com/$owner_repo" DOCX_REF="$ref" DOCX_PNG_DIR="$build/png" \
  pandoc -f gfm -t docx \
    --lua-filter scripts/docs/docx-filter.lua \
    --shift-heading-level-by=-1 \
    --toc --toc-depth=2 --number-sections \
    -M title="$title" \
    -M subtitle="Version $version, generated from the repository at $ref" \
    -M date="$(date +%Y-%m-%d)" \
    --resource-path=".:$tad" \
    -o "$docx" "$build/tad.md" "$build/adr-appendix.md"

# 5. Checks on what was produced.
fail=0
text="$build/docx.txt"
pandoc -f docx -t plain --wrap=none "$docx" -o "$text"

grep -E '^## ' "$tad" | sed -E 's/^## //; s/`//g' | while IFS= read -r h; do
  grep -qF "$h" "$text" || { echo "FAIL: TAD section '$h' missing from the DOCX"; echo x >> "$build/missing"; }
done
for f in docs/adr/[0-9][0-9][0-9][0-9]-*.md; do
  id="$(head -n1 "$f" | sed -E 's/^# (ADR-[0-9]{4}):.*/\1/')"
  grep -qF "$id:" "$text" || { echo "FAIL: $id missing from the DOCX appendix"; echo x >> "$build/missing"; }
done
[ -f "$build/missing" ] && fail=1

if grep -qE '^(flowchart|graph) (TB|LR|TD|RL|BT)' "$text"; then
  echo "FAIL: Mermaid source left in the DOCX"; fail=1
fi
media="$(unzip -l "$docx" | grep -c 'word/media/' || true)"
if [ "$media" -ne "$n_fig" ]; then
  echo "FAIL: the DOCX embeds $media images; expected the $n_fig draw.io figures"; fail=1
fi
if grep -qE '[0-9]{12}' "$text"; then
  echo "FAIL: a 12-digit run (account-ID shape) is in the DOCX text"; fail=1
fi
if grep -qE '(^|[^0-9a-f])[0-9a-f]{40}([^0-9a-f]|$)' "$text"; then
  echo "FAIL: a 40-hex run (commit-SHA shape) is in the DOCX text"; fail=1
fi
deny="scripts/validate/local-denylist.txt"
if [ -f "$deny" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$deny" > "$build/deny.txt" || true
  if [ -s "$build/deny.txt" ] && grep -qiFf "$build/deny.txt" "$text"; then
    echo "FAIL: a local-denylist term is in the DOCX text (term not printed)"; fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "docs-docx: FAILED ($docx kept for inspection)"
  exit 1
fi
# Build stamp: the commit (and whether the tree was clean) and the link ref;
# scripts/docs/release.sh publishes only a DOCX stamped for its own commit.
if [ -z "$(git status --porcelain)" ]; then
  echo "$(git rev-parse HEAD) $ref" > "$build/stamp"
else
  echo "dirty $ref" > "$build/stamp"
fi
size="$(wc -c < "$docx" | tr -d ' ')"
echo "docs-docx: OK $docx ($size bytes, $n_fig figures, links at $ref)"
