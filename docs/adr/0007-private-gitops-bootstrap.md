# ADR-0007: Private repository GitOps bootstrap

**Status:** Accepted
**Date:** 2026-09-01

## Context

This repository is private. Phase 2.2 installed Argo CD itself but
deliberately created no `Application`, `AppProject`, or `ApplicationSet`
— those are the declarative resources GitOps is meant to reconcile, and
none of them can exist until Argo CD can actually read this repository's
own content over the network. That first read is the one point in the
whole design where something must be imperative: Argo CD has no way to
discover a repository credential from a repository it cannot yet read.

Every credential mechanism Argo CD supports for a private Git repository
was considered:

- **Public repository.** Rejected — this repository is deliberately
  private (portfolio code under active development, not yet ready for
  unreviewed public exposure), and switching visibility to sidestep the
  credential question is a scope-avoidance move, not a design decision.
- **HTTPS with a Personal Access Token.** Rejected — a PAT scoped to a
  personal account is broader than this one repository by default (or
  requires fine-grained scoping that still ties the credential to a
  human identity), is awkward to rotate without touching every consumer,
  and is exactly the kind of credential this project's own security
  discipline (`AGENTS.md`, `SECURITY.md`) treats as a smell.
- **GitHub App.** Rejected for this phase — a GitHub App is the right
  answer once many repositories and many consumers need scoped,
  centrally-rotatable access, but for one lab cluster reading one
  repository it is meaningfully more infrastructure (app registration,
  private key rotation, installation management) than the problem needs.
- **Repository-scoped, read-only SSH deploy key.** **Selected.** A
  deploy key is bound to exactly one repository by GitHub's own design —
  it cannot be reused to access anything else, accidentally or
  otherwise. Read-only is enforced by GitHub itself, not by convention.
  It requires no app registration and no dependency on any human
  account's own credentials. Its blast radius if ever leaked is exactly
  this one repository, read-only.

## Decision

- **Exactly two objects are ever created imperatively**: the Argo CD
  repository-credential `Secret` and the root `Application`
  (`platform-bootstrap`). Every other GitOps object — the `AppProject`,
  the `ApplicationSet`, the two generated `Application` objects, the
  `staging`/`production` namespaces, and their `ConfigMap`s — is
  rendered by the `gitops/bootstrap` Helm chart and reconciled by Argo
  CD from Git, never `kubectl apply`-ed by hand.
- **The credential is excluded from Git entirely.** The private half of
  the deploy key lives only at `.local/gitops/github-deploy-key`
  (gitignored, mode `0600`) and inside the cluster as the
  `eks-gitops-platform-project-repo` Secret — never as a file in this
  repository, never in a commit, never printed by any script.
- **Root → AppProject/ApplicationSet relationship**: the root
  `Application` points at `gitops/bootstrap` (a dependency-free Helm
  chart) and passes its own Git revision through as a Helm value
  (`gitRevision`), so the `ApplicationSet` it renders — and therefore
  every `Application` that `ApplicationSet` generates — always reads
  from the exact same revision as the root itself. There is no second,
  independently-drifting revision reference anywhere in this design.
- **Environment generation**: a single, deterministic Helm `list`
  generator (not a `git`/`directory` generator) produces exactly two
  elements, `staging` and `production`, each pointing at its own
  `gitops/environments/<env>/` path. Adding a third environment requires
  an explicit, reviewed change to `gitops/bootstrap/values.yaml` — it is
  not something a stray file drop could trigger.
- **Self-heal and prune** are enabled on the root `Application` and on
  every generated `Application`. This is a single local `kind` cluster
  with no other tenant, no production traffic, and no shared blast
  radius to protect against automated reconciliation — the tradeoffs
  that justify disabling `selfHeal` in a real multi-tenant production
  environment (see the `teo-devops/Argo-cd-Labs` and internal
  `docs/architecture/technical-architecture.md` promotion-model
  discussion) do not apply here.
- **Namespace ownership and cleanup**: `staging`/`production` are
  created via `CreateNamespace=true` plus `managedNamespaceMetadata`
  carrying the same `eks-gitops-lab-lite.local/owner: gitops-bootstrap`
  label already used for the Argo CD namespace itself (Phase 2.2). A
  namespace is only ever deleted by `lab/gitops/uninstall.sh` when it
  carries that exact label and an exhaustive, `kubectl api-resources
  --namespaced`-driven inventory shows nothing unexpected remains — the
  same discipline Phase 2.2 already established for the `argocd`
  namespace.
- **AppProject scope**: exactly one `sourceRepos` entry (this
  repository's own SSH URL), exactly the `staging`/`production`
  destination namespaces, an empty `clusterResourceWhitelist`, no
  project `roles`. `CreateNamespace=true` was verified empirically
  during this phase's lifecycle test to work with that empty
  cluster-resource whitelist — Argo CD's namespace-creation sync option
  is a controller-level step, not a tracked-resource apply, so it does
  not require a `Namespace` grant here. If a future change proves
  otherwise, the minimum necessary grant should be added and this
  paragraph updated to say so.

## Alternatives Considered

See "Context" above for the full credential-mechanism comparison
(public repo / PAT / GitHub App / deploy key).

- **A single combined `Application` that both installs Argo CD-adjacent
  config and deploys workloads**: rejected — mixing the imperative
  bootstrap boundary with the declarative workload boundary defeats the
  entire purpose of separating them in ADR-0001/ADR-0003.
- **A `git`/`directory` ApplicationSet generator instead of a
  deterministic `list`**: rejected for this phase — a directory
  generator would let a new file under `gitops/environments/` silently
  become a new environment with no explicit review step, which is
  exactly the kind of "generates, does not authorize" risk
  `docs/architecture/technical-architecture.md`'s "Application Delivery
  and Promotion" section already warns about for `ApplicationSet` more
  generally.

## Consequences

### Positive

- The only credential in this design is scoped to exactly one
  repository, read-only, and revocable independently of any human
  account.
- Every object after the root `Application` is Git-reconciled, reviewable
  in a PR, and self-healing — consistent with this project's existing
  imperative/declarative boundary (Phase 2.2's TAD section of the same
  name).
- The lifecycle test proves, not asserts, that a single-environment
  drift self-heals without affecting the other environment — a concrete,
  executable demonstration of environment isolation at the
  `Application`/namespace level.

### Negative

- A repository-scoped deploy key does not scale past one repository; a
  future multi-repository design will need the GitHub App path this ADR
  explicitly deferred.
- The deterministic `list` generator means adding a third environment is
  a manual, reviewed chart change rather than something that falls out
  of a directory convention — a deliberate tradeoff, not an oversight.

## Security and Cost Implications

No AWS cost impact (local `kind` cluster only). Security posture is
improved relative to a PAT or a personal SSH key: the credential this
phase introduces is read-only, single-repository-scoped, stored only in
`.local/` (gitignored) and inside the cluster as a labeled Secret, and
is never printed by any script (`lab/gitops/repo-setup.sh`/`repo-remove.sh`
verify identity via SHA256 hashes and non-secret metadata only, never by
reading back and printing the key itself).

## Validation Method

`make gitops-render` proves the rendered chart contains exactly one
`AppProject`, one `ApplicationSet` with exactly two generator elements,
zero `Secret` objects, and no wildcard `sourceRepos`/`destinations`.
`make gitops-test-lifecycle` proves, against a real cluster: bootstrap
from absent, a true no-op on a second bootstrap (root `Application`
`resourceVersion` unchanged), single-environment drift self-healing
within 90 seconds while the other environment is provably unaffected,
and a foreground-cascading uninstall that removes exactly the Phase 2.3
workload resources while leaving Argo CD, its CRDs, the repository
Secret, and the deploy key untouched.
