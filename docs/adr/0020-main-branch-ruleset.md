# ADR-0020: Ruleset for the main branch

**Status:** Accepted
**Date:** 2026-11-17

## Context

[ADR-0009](0009-repository-governance-baseline.md) designed a ruleset for
`main` but could not apply it: the repository was private on GitHub
Free. It is now public, and rulesets are available at no cost. Measured
on 2026-11-17 through the GitHub REST API as the owner:
`GET branches/main/protection` returns 404 `Branch not protected` and
`GET rulesets` returns `[]`. `main` is protected by process only.

The design in ADR-0009 required one check, `validate`. Since then three
more workflows check pull requests: `terraform` (job `emulator`,
ADR-0018), `image` (job `build, scan, SBOM`, ADR-0017) and `promotion`
(job `verify promoted images`). All three were filtered with
`on.pull_request.paths`. A required check from a filtered workflow never
reports on a pull request outside its paths, so that pull request waits
forever; leaving those checks optional lets a failing one merge.

## Decision

- **One repository ruleset, `main`**, kept as code in
  `.github/rulesets/main.json`, targeting exactly `refs/heads/main`,
  enforcement `active`:
  - blocks deletion and non-fast-forward updates (force pushes);
  - requires a pull request with 0 approvals (one maintainer cannot
    approve their own PR), all review threads resolved, and merge commits
    only (`allowed_merge_methods: ["merge"]`, as the merge-button policy
    of ADR-0009 already does);
  - requires four checks, strict (the branch must be up to date with
    `main`): `validate`, `emulator`, `build, scan, SBOM` and
    `verify promoted images`. Each is pinned to the GitHub Actions app
    (`integration_id` 15368), so a commit status posted by another app
    or token cannot satisfy it;
  - no bypass actors, the owner included.
- **Path filters move from the trigger into a job, for pull requests
  only.** `terraform`, `image` and `promotion` run on every pull request.
  Their first job, `<workflow> paths`, runs `scripts/ci/changed-paths.sh`
  with the workflow's path list (git glob pathspecs, diff from the merge
  base). The required job has `needs: changes` and
  `if: ${{ !cancelled() && needs.changes.outputs.relevant != 'false' }}`:
  it is skipped, which a required check counts as passed, only when the
  answer is exactly `false`. If the paths job fails or answers nothing,
  the required job runs. `on.push.paths` stays (push runs gate nothing)
  and must equal the paths job's list.
- **The live ruleset is compared with the file** by
  `scripts/governance/ruleset.sh diff` (`make governance-diff`,
  read-only). `apply --confirm` creates or updates it and saves the
  previous version; `enforcement disabled|active --confirm` is the
  break-glass. None of it runs in CI.
- **Contract (`check-repo-governance`, in `make validate`):** the ruleset
  file keeps every rule above; every required check is the name of
  exactly one job, in a workflow that runs on every pull request; a
  required job may be skipped only through its paths job with the
  fail-open condition; the paths list names the workflow itself and
  `changed-paths.sh` and equals `on.push.paths`; every workflow that runs
  on pull requests has a required job.
- **Applying is a separate, authorized step (5.3b)**, after this change
  is on `main`, together with turning on secret scanning and push
  protection (free on a public repository; ADR-0009 left them open) and
  the "Update branch" button that strict checks make necessary.

## Alternatives Considered

- **Require only `validate`.** Rejected: a Terraform regression, an
  image with a fixable HIGH vulnerability, or an unsigned promoted image
  could merge with its check red.
- **Classic branch protection.** Rejected: rulesets can be read and
  written as one JSON document, show in the API to anyone with read
  access, and can be disabled without being deleted.
- **A third-party change-detection action.** Rejected: the Actions policy
  allows GitHub-owned actions only (ADR-0009); `git diff` in a
  15-line script does the same.
- **Skip the required job when the paths job fails.** Rejected: a broken
  paths job would then pass every required check unseen. Running the
  job costs minutes; skipping it could cost a regression.
- **Owner as bypass actor.** Rejected: a bypass is used under pressure,
  without the checks. The break-glass disables the ruleset on purpose
  and is recorded.
- **Required approvals.** Rejected for now: with one maintainer, GitHub
  does not let the author approve their own pull request.

## Consequences

- Nothing reaches `main` without a pull request whose four checks
  passed or were skipped by their paths job, up to date with `main`.
- Every pull request starts three short paths jobs (about 15 seconds
  each), and the required jobs only when their paths changed.
- Strict checks re-run after every merge to `main` for open pull
  requests; back-to-back Terraform pull requests wait for the emulator
  (about six minutes) each time.
- Renaming a required job blocks every pull request until the ruleset
  names it. `check-repo-governance` fails first; the runbook says to
  change the ruleset before the job.
- A required workflow that breaks blocks its own fix; the break-glass
  is the way out.

## Security and Cost Implications

- Closes the gap ADR-0009 accepted: no direct push, force push or
  deletion of `main`, and no merge with a failing check.
- `ruleset.sh` needs an admin token on the operator's machine; no
  workflow gets any write permission.
- Cost: USD 0. About 45 seconds of extra runner time per pull request.

## Validation Method

- `make check-repo-governance` passes on the repository.
- `make check-repo-governance-regression`: the real files are accepted;
  22 mutations are rejected (bypass actor, disabled, wildcard target, no
  force-push rule, squash, unresolved threads, not strict, no
  `integration_id`, a dropped or unknown check, a renamed job, paths on
  the trigger, a fail-closed or other skip condition, a paths list that
  differs or omits the workflow, no call to the script, a duplicate job
  name, a pull request workflow with no required job, no
  `governance-diff`, not in `validate`), and `changed-paths.sh` answers
  correctly for docs-only, relevant, push and manual runs and answers
  nothing on a missing or unknown commit.
- On this change's own pull request the paths jobs answer and the
  required jobs run because their workflows changed.
- After 5.3b: `make governance-diff` reports no drift; a docs-only test
  pull request shows the three required jobs skipped and becomes
  mergeable; a direct push and a force push to `main` are rejected.

## Applied (Phase 5.3b, 2026-11-17)

- `ruleset.sh apply --confirm` created ruleset `main`;
  `make governance-diff` reports no drift. "Update branch", secret
  scanning and push protection were turned on.
- Docs-only test pull request: `validate` ran; `emulator`,
  `build, scan, SBOM` and `verify promoted images` were skipped by their
  paths jobs and counted as passed; the pull request became mergeable
  and was closed without merging.
- A direct push to `main` was rejected (GH013: changes must be made
  through a pull request, four required checks expected), and so was a
  force push (cannot force-push to this branch). `main` did not move.
