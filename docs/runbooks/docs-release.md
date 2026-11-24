# Runbook: Publishing the architecture documents (DOCX and diagrams)

The Markdown in `docs/` is the source of truth. The draw.io SVGs live
next to their sources in `docs/architecture/diagrams/` and are committed.
The DOCX is derived, so it is never committed: it is published as a
GitHub Release asset, one release per TAD version.

Everything here runs locally. CI needs neither pandoc nor draw.io.

## Prerequisites

- pandoc 3.x and the draw.io desktop app (its CLI is `drawio`, or set
  `DRAWIO=<path>`);
- `gh` signed in to the account that owns the repository;
- `unzip` (on macOS and most Linux distributions by default).

## Diagrams

After editing a `.drawio` file in draw.io (save it uncompressed:
File → Properties → uncheck Compressed):

```bash
make diagrams        # re-export every SVG, then make check-diagrams
```

`make check-diagrams` runs in `make validate`. It fails when an SVG no
longer holds the same shapes as its source, so a source edited without a
fresh export cannot merge.

## DOCX

```bash
make docs-docx
```

This writes `dist/technical-architecture-<version>.docx`:

- the TAD, its H2 sections as numbered chapters, with a table of contents;
- the four draw.io figures as PNG (Mermaid blocks become a pointer to
  them, since pandoc cannot draw Mermaid);
- an appendix with each ADR's status and Decision section;
- relative links rewritten to GitHub URLs at the tag `docs-v<version>`.

It then reads the DOCX back and fails if:

- a TAD section or ADR is missing;
- Mermaid source remains;
- the figures are not all embedded;
- the text matches the generic patterns of `check-forbidden-terms` or a
  term in the optional local denylist.

## Release (public)

Publish once per TAD version, after the change that bumped the version
is merged:

```bash
git checkout main && git pull --ff-only
make docs-docx
make docs-release CONFIRM=yes
```

`docs-release` refuses unless all of these hold:

- `CONFIRM=yes`;
- you are on `main`, with a clean tree, equal to `origin/main`;
- the tag does not exist yet, locally or on GitHub;
- the DOCX was built by `docs-docx` from this exact commit for this tag.

It creates the tag `docs-v<version>` on that commit, with the DOCX and the
SVGs as assets. `make docs-release-regression`, which runs in
`make validate`, tests every refusal with a fake `gh`.

A published release is public. To withdraw one, delete the release and
its tag on GitHub; anyone who already downloaded it keeps their copy.
