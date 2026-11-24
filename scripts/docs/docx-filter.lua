-- Pandoc filter for `make docs-docx` (Phase 7c).
--
--  * Mermaid blocks: pandoc cannot draw them, and the DOCX must not ship
--    raw diagram source; each becomes a one-line pointer to the draw.io
--    figures, which are embedded as PNG.
--  * Images under diagrams/*.svg: replaced by the PNG exports that
--    scripts/docs/docx.sh renders into the build directory (DOCX_PNG_DIR).
--  * Relative links to repository files: rewritten to absolute GitHub URLs
--    at DOCX_REF (a tag or branch), because a link to "../adr/x.md" means
--    nothing inside a Word document. In-document anchors stay as they are.

local repo = os.getenv("DOCX_REPO_URL") or ""
local ref = os.getenv("DOCX_REF") or "main"
local png_dir = os.getenv("DOCX_PNG_DIR") or ""

-- Path of a link target relative to the repository root. Sources are the
-- TAD (docs/architecture) and ADR Decision sections (docs/adr).
local function repo_path(target)
  if target:match("^%.%./%.%./") then
    return target:gsub("^%.%./%.%./", "")
  elseif target:match("^%.%./") then
    return "docs/" .. target:gsub("^%.%./", "")
  elseif target:match("^%d%d%d%d%-.*%.md") then
    return "docs/adr/" .. target
  else
    return "docs/architecture/" .. target
  end
end

function CodeBlock(el)
  if el.classes:includes("mermaid") then
    return pandoc.Para({ pandoc.Emph({ pandoc.Str(
      "[Diagram drawn in the Markdown version of this document; the draw.io figures under \"Diagrams (draw.io)\" show the same architecture.]") }) })
  end
end

function Image(el)
  local name = el.src:match("^diagrams/(.+)%.svg$")
  if name and png_dir ~= "" then
    el.src = png_dir .. "/" .. name .. ".png"
  end
  return el
end

function Link(el)
  local t = el.target
  if t:match("^%a[%w+.-]*:") or t:match("^#") or repo == "" then
    return el
  end
  local path, anchor = t:match("^([^#]*)(#?.*)$")
  if path == "" then
    return el
  end
  el.target = repo .. "/blob/" .. ref .. "/" .. repo_path(path) .. anchor
  return el
end
