#!/bin/sh
# Exports every docs/architecture/diagrams/*.drawio to an SVG next to it
# with the draw.io desktop CLI (Phase 7b, local only: CI never needs
# draw.io). Each SVG embeds a copy of its source, which
# `make check-diagrams` compares with the .drawio file, so an edited
# source without a fresh export fails `make validate`.
#
# DRAWIO=<path> overrides the CLI (default: `drawio` on PATH, then the
# macOS app bundle).
set -eu

dir="docs/architecture/diagrams"
drawio="${DRAWIO:-}"
if [ -z "$drawio" ]; then
  if command -v drawio >/dev/null 2>&1; then
    drawio="drawio"
  elif [ -x "/Applications/draw.io.app/Contents/MacOS/draw.io" ]; then
    drawio="/Applications/draw.io.app/Contents/MacOS/draw.io"
  else
    echo "FAIL: draw.io desktop CLI not found (install draw.io or set DRAWIO=<path>)" >&2
    exit 1
  fi
fi

found=0
for src in "$dir"/*.drawio; do
  [ -f "$src" ] || continue
  found=$((found + 1))
  out="${src%.drawio}.svg"
  "$drawio" --export --format svg --embed-diagram --embed-svg-fonts false \
    --border 10 --output "$out" "$src" >/dev/null 2>&1 || {
    echo "FAIL: draw.io could not export $src" >&2
    exit 1
  }
  echo "OK: $src -> $out"
done
[ "$found" -gt 0 ] || { echo "FAIL: no .drawio file under $dir" >&2; exit 1; }

sh scripts/validate/check-diagrams.sh
