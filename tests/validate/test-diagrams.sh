#!/bin/sh
# Regression tests for scripts/validate/check-diagrams.sh (Phase 7b): the
# checker, unmodified, against throwaway copies of the diagram sources,
# their SVG exports and the TAD, each with one mutation. No draw.io
# needed. Backs `make check-diagrams-regression`. Touches nothing outside
# one mktemp -d root.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$here/scripts/validate/check-diagrams.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0; n=0
run_case() { # $1=description $2=accept|reject $3=setup function
  n=$((n + 1)); fx="$root/case$n"
  mkdir -p "$fx/diagrams"
  cp "$here"/docs/architecture/diagrams/*.drawio "$here"/docs/architecture/diagrams/*.svg "$fx/diagrams/"
  cp "$here/docs/architecture/technical-architecture.md" "$fx/tad.md"
  "$3" "$fx"
  if DIAGRAMS_DIR="$fx/diagrams" TAD="$fx/tad.md" sh "$checker" > "$fx.out" 2>&1; then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$fx.out" >&2; fail=$((fail + 1)); fi
}
mutate() { # $1=file $2=sed expression; a mutation that changes nothing fails loudly
  cp "$1" "$1.orig"; sed -i.bak -e "$2" "$1" && rm -f "$1.bak"
  if cmp -s "$1" "$1.orig"; then echo "FAIL: mutation '$2' changed nothing in $1" >&2; exit 1; fi
  rm -f "$1.orig"
}
src() { echo "$1/diagrams/system-topology.drawio"; }

real() { :; }
run_case "the real sources, exports and TAD are accepted" accept real

view_only() { mutate "$(src "$1")" 's/grid="1" gridSize="10"/grid="0" gridSize="20"/'; }
run_case "a view-only change (grid) without a re-export is accepted" accept view_only
label() { mutate "$(src "$1")" 's/own instance/shared instance/'; }
run_case "a label edited after the export is rejected" reject label
moved() { mutate "$(src "$1")" 's/<mxGeometry x="420" y="350" width="200"/<mxGeometry x="430" y="350" width="200"/'; }
run_case "a shape moved after the export is rejected" reject moved
new_cell() { mutate "$(src "$1")" 's#</root>#<mxCell id="extra" value="new" style="rounded=1;" vertex="1" parent="1"><mxGeometry x="1" y="1" width="10" height="10" as="geometry"/></mxCell></root>#'; }
run_case "a shape added after the export is rejected" reject new_cell
edge_target() { mutate "$(src "$1")" 's/source="t-hubvel" target="t-store"/source="t-hubvel" target="t-obs"/'; }
run_case "a connector re-pointed after the export is rejected" reject edge_target
no_svg() { rm "$1/diagrams/delivery-promotion.svg"; }
run_case "a source without its SVG is rejected" reject no_svg
orphan_svg() { cp "$1/diagrams/delivery-promotion.svg" "$1/diagrams/orphan.svg"; }
run_case "an SVG without its source is rejected" reject orphan_svg
not_embedded() { mutate "$1/diagrams/secrets-identity.svg" 's/ content="[^"]*"//'; }
run_case "an SVG exported without the embedded source is rejected" reject not_embedded
swapped() { cp "$1/diagrams/delivery-promotion.svg" "$1/diagrams/secrets-identity.svg"; }
run_case "an SVG exported from another diagram is rejected" reject swapped
unlinked() { mutate "$1/tad.md" '/diagrams\/reference-application\.svg/d'; }
run_case "an SVG the TAD does not link is rejected" reject unlinked

echo ""
echo "test-diagrams: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-diagrams: FAILED"; exit 1; }
echo "test-diagrams: OK"
