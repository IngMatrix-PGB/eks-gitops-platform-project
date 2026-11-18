# Runbook: Repository governance (main ruleset)

The ruleset that protects `main` is `.github/rulesets/main.json`
([ADR-0020](../adr/0020-main-branch-ruleset.md)). Changes to it go
through a pull request like any other file, then are applied by hand.

## Prerequisites

- `gh` authenticated as a repository admin (`GH_TOKEN`), and `jq`.
- Run from the repository root.

## Steps

### Check for drift

1. `make governance-diff` (read-only).
2. `OK` means the live ruleset matches the file. `DRIFT` prints the
   difference: either apply the file (next section) or, if the live
   change was intended, bring it into the file through a pull request.

### Change the ruleset

1. Edit `.github/rulesets/main.json` in a pull request;
   `make check-repo-governance` must pass.
2. After it merges: `bash scripts/governance/ruleset.sh apply --confirm`.
   The previous live version is saved in
   `.tools/out/governance/ruleset-before.json`; the command ends with a
   diff.

### Rename or add a required job

The ruleset names checks by job `name:`, so the two change together:

1. In one pull request, change the job and the matching `context` in
   `main.json`; `make check-repo-governance` must pass.
2. Before merging it, apply the ruleset from that branch
   (`ruleset.sh apply --confirm`). Its checks now report under the
   required names and it can merge. Other open pull requests need
   "Update branch" to pick up the new job.
3. A workflow filtered by paths gets a `<workflow> paths` job and the
   fail-open `if:` (see `.github/workflows/image.yml`).

### Break-glass

Only when a required check cannot pass for reasons outside the change
(the required workflow itself is broken, GitHub Actions is down) and the
fix cannot wait:

1. `bash scripts/governance/ruleset.sh enforcement disabled --confirm`.
2. Merge the fix through its pull request.
3. `bash scripts/governance/ruleset.sh enforcement active --confirm`
   (ends with a diff).
4. Record when, why and which pull request in the pull request itself.

Never delete the ruleset to get around it.

## Verification

- `make governance-diff` ends with `OK`.
- A docs-only pull request shows `validate` run and `emulator`,
  `build, scan, SBOM` and `verify promoted images` skipped, and can be
  merged.
- `git push origin HEAD:main` from a local commit is rejected by GitHub.

## Rollback

- Ruleset change: revert `main.json` through a pull request and apply
  again. The previous live version, for reference, is in
  `.tools/out/governance/ruleset-before.json`.
- Turn protection off entirely: `enforcement disabled --confirm`.

Test line for the Phase 5.3b docs-only check (never merged).
