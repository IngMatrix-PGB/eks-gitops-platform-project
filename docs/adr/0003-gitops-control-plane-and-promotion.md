# ADR-0003: GitOps control plane and promotion

**Status:** Accepted
**Date:** 2026-08-31

## Context

A GitOps controller is, by construction, highly privileged: whatever it
can reach, it can mutate. A reviewed pull request alone does not stop a
compromised controller or an over-privileged cluster credential from
mutating a cluster directly — branch protection constrains what enters
Git, not what an already-privileged, already-running identity can do.
Promotion tooling that commits straight to a production-tracked branch
with no review, and a shared dependency reconciled from a mutable
reference with no immutable pin, are both well-documented ways this kind
of platform fails.

## Decision

### Reconciliation

Argo CD reconciles a protected `main` branch of this repository as the
desired-state source. `ApplicationSet` generates `Application` objects
from an explicit, closed environment list/matrix — environment is never
free text. `ApplicationSet` **generates; it does not authorize** —
promotion approval is a separate control (below).

### Pinning

`main` being tracked continuously is expected, correct GitOps behavior;
safety comes from the branch being **protected** (PR review,
`CODEOWNERS`, blocking checks), not from being a tag. What must always be
pinned immutably is everything the repository *references from outside
itself*: image digests, Helm/OCI chart versions, external Git sources by
tag or commit, Terraform providers/modules, and GitHub Actions by
verified commit SHA.

### Promotion

- **Staging** reconciles automatically from the protected branch.
- **Production** is promoted only through a **separate, explicit pull
  request** that edits the pinned external-dependency values (a chart
  version bump, an image digest bump) — never a direct commit, never a
  one-click bypass.
- Once a remote exists, this PR gate is enforced by `CODEOWNERS`, branch
  protection, and blocking required checks with a rendered diff.
- **The PR gate is necessary, not sufficient, on its own.** It is paired
  with:
  - `AppProject` boundaries per trust domain — allowed source
    repositories, allowed destination cluster/namespace pairs, and a
    resource-kind allow/deny list.
  - Argo CD RBAC restricting who can act on which `AppProject`.
  - A restricted set of principals allowed to modify `ApplicationSet`
    definitions themselves.
  - A documented sync/prune policy (`selfHeal`, `prune`) per environment,
    stated explicitly rather than left to individual defaults.
  - Least-privilege cluster credentials held by Argo CD — never a
    blanket cluster-admin credential.

### Rollback

Defined in Git terms: revert the promotion commit and let Argo CD
reconcile the previous pinned state from the same protected branch.

### Progressive Delivery

Explicitly **not** part of the main production promotion path. If added
later, it is an additional safety layer on top of the controls above —
never a replacement for any of them.

## Alternatives Considered

- **Flux**: a credible alternative controller; not chosen here to stay
  consistent with the `ApplicationSet` generator model this project
  standardizes on.
- **Treating the PR gate as the complete control**: rejected — leaves a
  compromised controller or over-privileged credential able to mutate a
  cluster with nothing else standing in the way.
- **Prohibiting Argo CD from ever tracking `main`**: rejected — would
  contradict the monorepo's own GitOps flow and adds no safety beyond
  branch protection plus pinned external dependencies.
- **Auto-promotion after a staging soak time, no human review**: rejected
  for the primary path.

## Consequences

### Positive

- Every environment's state is deterministic and reproducible, because
  every external reference is immutable while the tracked branch itself
  stays reviewable.
- Safety does not rest on Git review alone — it also constrains what an
  already-privileged Argo CD identity can do.
- Rollback reuses the same reviewed path as any other change.

### Negative

- Slower than one-click promotion for low-risk, frequent changes.
- Requires `CODEOWNERS`, branch protection, `AppProject`s, and Argo CD
  RBAC to actually exist once a remote is configured — meaningless until
  then (see the TAD's risk table).
- Contributors must understand the distinction between "the branch Argo
  CD tracks" and "the external references that branch's content must
  keep pinned."

## Security and Cost Implications

This is the project's primary governance control, split across a Git
layer (PR, branch protection) and a runtime layer (`AppProject`, RBAC,
least-privilege credentials). No cost implication.

## Validation Method

Once a remote and a cluster exist: a direct push/commit to the
production-tracked branch must fail; a merged PR without a required
check passing must be blocked; an `AppProject` must reject a
source/destination outside its allowlist even when Git history is clean;
and a rollback runbook must be exercised at least once against the local
lab. All `NOT IMPLEMENTED` today.
