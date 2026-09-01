# ADR-0001: Platform scope and repository boundaries

**Status:** Accepted
**Date:** 2026-08-31

## Context

The project needs a clear, upfront answer to three recurring questions
before any code is written: where does infrastructure code live relative
to GitOps manifests, where does Terraform's authority end and Argo CD's
begin, and how much infrastructure-provisioning capability belongs in the
MVP. Deferring these decisions tends to produce repository boundaries
that no longer match what the code actually does, and imperative tooling
that keeps "just patching" a component after a GitOps controller was
supposed to take it over.

## Decision

- **Monorepo.** Terraform modules, GitOps manifests, the standard
  workload chart, and documentation live in one repository. Splitting
  them out is deferred until a concrete ownership or release-cadence
  need justifies it — see "Criteria for a future split" below.
- **Terraform owns AWS infrastructure**: VPC, EKS control planes and
  node groups, IAM baseline, KMS, EKS Pod Identity Associations, and
  Argo CD's own initial bootstrap installation.
- **Argo CD owns Kubernetes desired state after bootstrap**: every
  `Application`/`ApplicationSet`/`AppProject` object and, where safe, its
  own Helm values. Once Argo CD can reconcile something, Terraform stops
  touching it — no ad hoc post-bootstrap patching outside the GitOps flow.
- **`docs/architecture/technical-architecture.md` (the TAD) is the
  authoritative, reviewable source of truth.** Diagrams live inline in
  the TAD as Mermaid; a standalone draw.io diagram and a polished DOCX
  export are derived artifacts generated later (Phase 7), never
  hand-maintained as an independent source.
- **Crossplane (or an equivalent self-service infrastructure-provisioning
  layer) is out of scope for the MVP.** AWS infrastructure is created
  exclusively through Terraform until version pinning, CI gating, and
  freedom from out-of-band dependencies are proven there first.

### Criteria for a future repository split

Split a component out of the monorepo only when at least one of these
becomes true, and record the split as its own ADR when it does:

- The component needs an independent release cadence (e.g., the standard
  chart versioned and consumed by other, unrelated repositories).
- Ownership genuinely diverges (a different team owns it with different
  review requirements).
- Monorepo CI time or access-control granularity becomes a measured
  problem, not a hypothetical one.

## Alternatives Considered

- **Multiple repositories from day one**: rejected for the MVP — it
  multiplies CI/ownership surface before there is enough content to
  justify separate release cadences.
- **Terraform managing Argo CD configuration indefinitely**: rejected —
  defeats the purpose of adopting GitOps for the platform's own control
  plane and creates two competing sources of truth for the same
  component.
- **DOCX or a diagram tool as the primary architecture source**: rejected
  — neither is diff-friendly or fits a PR-review-based workflow.
- **Adopting Crossplane now, "carefully"**: rejected — the project has
  not yet proven basic pinning/CI discipline even for its simpler,
  primary Terraform path; adding a second infrastructure-provisioning
  paradigm before that is proven would repeat a well-known risk pattern
  (unpinned shared dependency, out-of-band credentials, no CI) rather
  than avoid it.

## Consequences

### Positive

- One place to review cross-cutting changes; a single documented point
  where imperative provisioning ends and GitOps reconciliation begins.
- Architecture review happens through the same PR flow as code, since the
  TAD is Markdown in the same repository.
- MVP scope stays achievable: one infrastructure-provisioning paradigm to
  get right before considering a second.

### Negative

- Monorepo CI time and ownership boundaries will need active management
  if the project grows significantly.
- Self-service infrastructure requests are not available in the MVP;
  teams use Terraform directly or a PR to shared modules.
- Producing the derived draw.io/DOCX artifacts is deferred work that
  must actually happen (Phase 7), not something produced ad hoc.

## Security and Cost Implications

No direct cost. Keeping Crossplane out of the MVP reduces the project's
current risk surface — self-service infrastructure catalogs concentrate
real operational risk exactly where this project has not yet proven its
own discipline (pinning, CI gating, no out-of-band dependencies).

## Validation Method

Structural review: the repository tree matches `README.md`; no
Terraform code touches an Argo-CD-managed custom resource after
bootstrap; no `XRD`, `Composition`, or Crossplane `Provider` manifest
exists anywhere in the repository while this ADR stands.
