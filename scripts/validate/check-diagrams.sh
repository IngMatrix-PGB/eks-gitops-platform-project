#!/bin/sh
# Verifies the draw.io diagrams (Phase 7b) without draw.io itself:
#
#  1. every docs/architecture/diagrams/*.drawio has an SVG export next to
#     it, and every SVG there has its .drawio source;
#  2. each SVG embeds a copy of its source (draw.io's --embed-diagram),
#     and that copy holds exactly the source's shapes and connectors:
#     same ids, labels, styles, endpoints, geometry and waypoints. A
#     source edited after its export fails here; `make diagrams`
#     re-exports;
#  3. every SVG is linked from the TAD (README may link it too).
#
# Limitation: the comparison covers what draws the diagram (cells and
# geometry), not draw.io's view settings (zoom, page size), which the
# export rewrites.
set -eu

dir="${DIAGRAMS_DIR:-docs/architecture/diagrams}"
tad="${TAD:-docs/architecture/technical-architecture.md}"

python3 -I - "$dir" "$tad" <<'PY'
import glob, html, os, re, sys
import xml.etree.ElementTree as ET

d, tad = sys.argv[1], sys.argv[2]
fail = []

def cells(root):
    out = {}
    for c in root.iter("mxCell"):
        g = c.find("mxGeometry")
        geo = ()
        if g is not None:
            pts = tuple((p.get("x"), p.get("y")) for p in g.iter("mxPoint"))
            # draw.io omits x and y when they are 0
            geo = (g.get("x", "0"), g.get("y", "0")) + tuple(g.get(k) for k in ("width", "height", "relative")) + (pts,)
        key = c.get("id")
        if key in out:
            fail.append(f"duplicate cell id {key!r}")
        out[key] = (c.get("value") or "", c.get("style") or "", c.get("parent"),
                    c.get("vertex"), c.get("edge"), c.get("source"), c.get("target"), geo)
    return out

def diagrams(root):
    res = {}
    for dg in root.iter("diagram"):
        model = dg.find("mxGraphModel")
        if model is None:
            fail.append(f"diagram {dg.get('id')!r} is compressed or empty; save it uncompressed")
            continue
        res[dg.get("id")] = cells(model)
    return res

sources = sorted(glob.glob(os.path.join(d, "*.drawio")))
svgs = sorted(glob.glob(os.path.join(d, "*.svg")))
if not sources:
    fail.append(f"no .drawio file under {d}")
for s in svgs:
    if not os.path.exists(s[:-4] + ".drawio"):
        fail.append(f"{s} has no .drawio source")

tad_text = open(tad, encoding="utf-8").read() if os.path.exists(tad) else ""
for src in sources:
    svg = src[:-7] + ".svg"
    name = os.path.basename(svg)
    if not os.path.exists(svg):
        fail.append(f"{src} has no SVG export ({name}); run make diagrams")
        continue
    try:
        want = diagrams(ET.parse(src).getroot())
    except ET.ParseError as e:
        fail.append(f"{src} is not valid XML: {e}")
        continue
    head = open(svg, encoding="utf-8").read()
    m = re.search(r'<svg\b[^>]*\scontent="([^"]*)"', head)
    if not m:
        fail.append(f"{svg} embeds no source (export with --embed-diagram); run make diagrams")
        continue
    try:
        got = diagrams(ET.fromstring(html.unescape(m.group(1))))
    except ET.ParseError as e:
        fail.append(f"{svg}'s embedded source is not valid XML: {e}")
        continue
    if want != got:
        fail.append(f"{svg} was exported from a different version of {os.path.basename(src)}; run make diagrams")
    if f"diagrams/{name}" not in tad_text:
        fail.append(f"{name} is not linked from {tad}")

for f in fail:
    print(f"FAIL: {f}")
if fail:
    print("check-diagrams: FAILED")
    sys.exit(1)
print(f"check-diagrams: OK ({len(sources)} diagrams)")
PY
