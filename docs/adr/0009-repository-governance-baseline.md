# ADR-0009: Repository governance baseline

**Status:** Accepted
**Date:** 2026-09-03

## Context

Phase 2.4 (the Standard Workload Contract) merged into `main` with no
repository-level governance baseline in place: no branch protection, no
Dependabot configuration, and a permissive GitHub Actions policy
(`allowed_actions: "all"`, no SHA-pinning requirement). Before External
Secrets, EKS, or SSO work begins, `main` needed a documented, honest
governance posture rather than an assumed one.

A read-only assessment (`.local/evidence/phase-2.5-repository-governance-plan.md`)
queried this repository's live GitHub configuration and found the
following, verified directly via the GitHub REST API on 2026-09-03:

- `GET /repos/{owner}/{repo}/branches/main/protection` → **HTTP 403**:
  `"Upgrade to GitHub Pro or make this repository public to enable this
  feature."`
- `GET /repos/{owner}/{repo}/rulesets` → the same HTTP 403, same message.
- `GET /repos/{owner}/{repo}/branches/main/protection/required_signatures`
  → the same HTTP 403 (part of the same gated feature family).

**This repository is private, on the GitHub Free plan, and both classic
branch protection and repository rulesets are unavailable for a private
repository under that plan.** This is not a permissions or token-scope
problem — every endpoint in the protection/ruleset family returned the
identical plan-upgrade message, while unrelated repository-level
settings (Dependabot, Actions permissions, merge-button configuration)
returned normal, non-gated responses and remain fully configurable.

The owner was presented with this finding and decided:

- **keep GitHub Free** — no paid plan will be purchased for cost
  reasons;
- **keep the repository private** — visibility will not change to work
  around the plan gate;
- **accept** that rulesets and classic branch protection are therefore
  unavailable for `main` under the current plan;
- **implement only the governance controls that are actually available
  today without payment.**

## Decision

Implement the subset of repository governance that GitHub Free permits
on a private repository, and document — rather than paper over — the
subset it does not:

1. **Dependabot vulnerability alerts**: enabled.
2. **Dependabot automated security updates**: enabled.
3. **Dependabot version updates**: configured for exactly one ecosystem,
   `github-actions` (`.github/dependabot.yml`) — the only
   dependency-manifest-shaped surface actually present in this
   repository. No `npm`, `docker`, `terraform`, `pip`, `bundler`, or
   other ecosystem entry was added, because none of them would detect
   anything real here (verified against the full tracked file list:
   no `go.mod`, `package.json`, `requirements.txt`, `Gemfile`,
   `Cargo.toml`, `Dockerfile`, or `*.tf` exists in this repository
   today). An empty or non-detecting ecosystem entry would be
   decoration, not governance.
4. **GitHub Actions allowed-actions policy**: restricted from `"all"` to
   `"selected"` with `github_owned_allowed: true`,
   `verified_allowed: false`, `patterns_allowed: []`. The repository's
   only workflow uses exactly one action, `actions/checkout`, which is
   GitHub-owned — this is a genuine no-op today, converting an existing
   practice into a structural guarantee.
5. **GitHub Actions SHA-pinning requirement**: `sha_pinning_required:
   true`. The repository already pins `actions/checkout` by immutable
   SHA (and `check-forbidden-terms.sh` already carries a narrow
   exception recognizing exactly that pin shape); this setting makes a
   floating-tag action reference fail closed platform-side instead of
   only being caught by local convention.
6. **Merge-button policy**: `allow_merge_commit` stays `true`;
   `allow_squash_merge` and `allow_rebase_merge` are turned **off**.
   This repository's established convention (every prior phase) is one
   real merge commit per PR, never a squash or a rebase — this makes
   that convention impossible to violate by mistake, without enabling
   "require linear history" (which would make a merge commit itself
   impossible).
7. **Default GitHub Actions token permissions**: confirmed unchanged —
   already `read` (least privilege), with
   `can_approve_pull_request_reviews: false`. No action needed; recorded
   here as verified, not assumed.

**Explicitly not created or enabled, and why:**

- **No ruleset, no classic branch protection, no required reviews, no
  required signatures, no merge queue, no bypass-actor list.** All of
  these require the plan upgrade or public visibility the owner
  declined. Simulating any of them (for example, via a status check
  that fails a direct-push detector after the fact) would be
  security theater, not a control — a compromised or careless actor
  with push access could still push directly to `main` today, and
  nothing GitHub-enforced stops them.
- **No secret-scanning configuration.** The API's `security_and_analysis`
  field for this repository returned empty rather than either a clear
  403 (like the protection family) or a clear disabled-state JSON (like
  the Dependabot toggles) — its exact availability for this specific
  private repository under GitHub Free could not be determined from the
  API and needs a direct check of the repository's Settings → "Code
  security" page. This is recorded as an open item (`Consequences`,
  below), not silently resolved.
- **No `.github/CODEOWNERS`.** With no review-requirement mechanism
  available (and `required_approving_review_count: 0` being the correct
  target even once one is), a CODEOWNERS file would have zero
  enforcement effect in a single-maintainer repository today. Revisit
  once a collaborator is added or the plan gate is lifted.

**`main` must not be described as protected.** It is not. The word used
throughout this ADR, the README, and the technical architecture document
is that `main` currently relies on **process** (every change goes
through a pull request, and a successful `validate` run is required
before merge, as a matter of maintainer discipline) rather than
GitHub-enforced, server-side protection.

## Alternatives Considered

- **Purchase GitHub Pro.** Rejected by the owner for cost reasons. The
  exact target ruleset this would unlock is fully specified and ready
  to apply unchanged (see `Validation Method`, below) — this is a
  deferred, not abandoned, path.
- **Make the repository public.** Rejected by the owner. Would unlock
  branch protection for free, but changes the repository's visibility
  posture, which is a decision independent of, and outweighing, this
  governance gap.
- **Simulate branch protection with a GitHub Actions workflow** (for
  example, a workflow that runs on `push` to `main` and flags — after
  the fact — a push that did not originate from a merged PR). Rejected:
  this cannot *prevent* a direct push, only report on one that already
  happened, and would create a false impression of enforcement where
  none exists. This ADR's own "do not describe `main` as protected"
  instruction exists specifically to avoid that false impression, so
  building a mechanism whose entire value proposition is a misleading
  impression would contradict the ADR itself.
- **Leave GitHub Actions policy and Dependabot as found (do nothing
  until the plan gate is resolved).** Rejected: the five mutations
  applied here are independent of the plan gate, free, reversible, and
  measurably improve the security posture today; there is no reason to
  wait on an unrelated, possibly-long-deferred decision to capture an
  available, zero-cost win.

## Consequences

### Positive

- Dependabot now alerts on, and can auto-remediate, vulnerable GitHub
  Actions dependencies (the only ecosystem present).
- The GitHub Actions attack surface is reduced: only GitHub-owned
  actions can run, and every action reference must be SHA-pinned
  platform-side, not merely by convention.
- The merge button can no longer produce a squash or rebase history by
  accident.
- The governance gap is documented honestly and specifically, with an
  exact, ready-to-apply ruleset design, rather than left implicit or
  glossed over.

### Negative

- **`main` has no server-enforced protection against a direct push, a
  force-push, or branch deletion.** This is real, currently-accepted
  residual risk, mitigated only by process (this project's own
  discipline of always working through a PR) and by the fact that this
  is a single-maintainer repository with no other party who could push
  without authorization.
- **Secret-scanning availability for this private repository remains
  unresolved** pending a direct check of the GitHub UI; until then, this
  repository's only secret-detection coverage is its own local,
  pattern-based `check-secrets.sh` / `check-forbidden-terms.sh` checks,
  which are narrower than GitHub's own scanner.
- **The Actions policy restriction (`selected` +
  `github_owned_allowed`) will block any future non-GitHub-owned action**
  from running until explicitly added to `patterns_allowed` — an
  intentional guardrail today, but a real point of friction the first
  time a third-party action is genuinely needed.

## Security and Cost Implications

No AWS cost impact (this ADR touches only GitHub repository settings and
two tracked files; no cluster, no cloud resource). No new credential or
secret was introduced. The owner explicitly declined the one paid option
(GitHub Pro) available to close the branch-protection gap, on cost
grounds — this is a deliberate, informed trade-off, not an oversight.

## Validation Method

- `.github/dependabot.yml` parses as valid YAML and declares exactly one
  `package-ecosystem: github-actions` entry.
- `GET /repos/{owner}/{repo}/vulnerability-alerts` returns `204` (enabled).
- `GET /repos/{owner}/{repo}/automated-security-fixes` returns
  `{"enabled": true}`.
- `GET /repos/{owner}/{repo}/actions/permissions` returns
  `allowed_actions: "selected"` and `sha_pinning_required: true`.
- `GET /repos/{owner}/{repo}/actions/permissions/selected-actions`
  returns `github_owned_allowed: true`, `verified_allowed: false`,
  `patterns_allowed: []`.
- `GET /repos/{owner}/{repo}/actions/permissions/workflow` still returns
  `default_workflow_permissions: "read"` (unchanged, confirmed not
  regressed).
- `GET /repos/{owner}/{repo}` returns `allow_merge_commit: true`,
  `allow_squash_merge: false`, `allow_rebase_merge: false`.
- `GET /repos/{owner}/{repo}/rulesets` and
  `GET /repos/{owner}/{repo}/branches/main/protection` continue to
  return HTTP 403 with the same plan-upgrade message, confirmed absent
  by design, not by accident.
- The `validate` GitHub Actions check continues to pass on every PR and
  on every push to `main` (job name `validate`, unchanged).
- If the account plan later changes (GitHub Pro purchased, or the
  repository made public), the exact ruleset payload recorded in
  `.local/evidence/phase-2.5-repository-governance-plan.md` (targeting
  `refs/heads/main` only; requiring the `validate` check, strict;
  blocking force-push and deletion; requiring conversation resolution;
  `required_approving_review_count: 0`; no bypass actors; no linear
  history) is ready to apply unchanged as a follow-up ADR, without
  re-doing this discovery.
