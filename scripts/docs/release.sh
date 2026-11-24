#!/bin/sh
# Publishes the documentation as a GitHub Release (Phase 7c, local only):
# tag docs-v<TAD version> on the current main commit, with the DOCX and the
# four SVG diagrams as assets. Outward-facing and public, so it refuses
# unless every condition below holds:
#
#   - CONFIRM=yes;
#   - on branch main, clean working tree, equal to origin/main;
#   - the tag docs-v<version> exists neither locally nor on GitHub;
#   - dist/technical-architecture-<version>.docx was built by
#     `make docs-docx` from this exact commit (its build stamp matches) and
#     linking to this tag.
#
# GitHub access comes from the caller's `gh` login (or GH_TOKEN); nothing
# is printed about it.
set -eu

tad="docs/architecture/technical-architecture.md"
version="$(sed -nE 's/^\| Version \| ([0-9]+\.[0-9]+\.[0-9]+) \|$/\1/p' "$tad")"
[ -n "$version" ] || { echo "FAIL: no version in $tad" >&2; exit 1; }
owner_repo="$(sed -nE 's/^GITOPS_OWNER_REPO="([^"]+)"$/\1/p' scripts/gitops/_lib.sh)"
tag="docs-v$version"
docx="dist/technical-architecture-$version.docx"
stamp="dist/build/stamp"

[ "${CONFIRM:-}" = "yes" ] || { echo "FAIL: publishing a public release needs CONFIRM=yes" >&2; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "FAIL: not on main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "FAIL: working tree not clean" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "FAIL: main differs from origin/main" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  echo "FAIL: tag $tag already exists" >&2; exit 1
fi
[ -f "$docx" ] && [ -f "$stamp" ] || { echo "FAIL: run make docs-docx first" >&2; exit 1; }
[ "$(cat "$stamp")" = "$(git rev-parse HEAD) $tag" ] || { echo "FAIL: $docx was not built from this commit for $tag; run make docs-docx again" >&2; exit 1; }

gh release create "$tag" --repo "$owner_repo" --target "$(git rev-parse HEAD)" \
  --title "Technical Architecture $version" \
  --notes "Technical Architecture Document $version as DOCX, generated from the repository at this tag, with the four draw.io diagrams as SVG. The Markdown in docs/ remains the source of truth." \
  "$docx" docs/architecture/diagrams/*.svg
echo "docs-release: OK $tag"
