# ADR-0008: Standard workload contract before SSO

**Status:** Accepted
**Date:** 2026-09-02

## Context

The Technical Architecture Document's Delivery Roadmap previously labeled "2.4" as
"Keycloak OIDC and Argo CD RBAC." A completed, read-only Public Upstream Gap Review
(`.local/evidence/public-upstream-gap-review-2026-09-02.md`) scored five candidate next
phases — GitOps hardening, the standard workload contract, an External Secrets local
proof, Keycloak/Argo CD SSO, and Crossplane preparation — across learning value,
portfolio value, security value, dependency readiness, implementation risk, local
resource cost, and future EKS reuse. The Standard Workload Contract scored highest
(31/35), ahead of Keycloak/Argo CD SSO (22/35), primarily because it introduces zero new
external runtime dependency (Keycloak has no official Helm chart — only an Operator or
raw `kubectl` manifests) and directly produces the artifact `docs/adr/0006-standard-workload-contract.md`
already committed this project to building.

## Decision

Implement the Standard Workload Contract as Phase 2.4. **Postpone, do not reject,**
Keycloak OIDC / Argo CD RBAC to a later, still-unnumbered phase.

**Why identity (SSO) is postponed, not rejected:** no real workload existed yet to
authorize access *to* — Phase 2.3 shipped only a `ConfigMap`. An access-control design is
more meaningful once there is an actual running service whose access model matters.
Separately, official Argo CD documentation has a confirmed gap (no sanctioned break-glass
pattern once OIDC is enabled once SSO is turned on — finding SSO-04 in the gap review)
that deserves a deliberate design pass of its own rather than being rushed ahead of the
workload contract to keep a stale roadmap label accurate.

## Alternatives Considered

- **Implement both in parallel.** Rejected — this is a single-operator portfolio project
  with no concurrency benefit and a real risk of half-finishing both.
- **Keep Keycloak/SSO as "2.4" as originally labeled, unchanged.** Rejected — the gap
  review's scoring and dependency-readiness finding stand: no official Keycloak Helm
  chart exists, and the Operator/raw-manifest paths add more moving parts than a
  contained Helm chart change with zero new runtime dependency.
- **Skip a workload contract entirely and go straight to a real EKS phase.** Rejected —
  ADR-0006 already commits to this chart, and every other deferred candidate (External
  Secrets, in particular) is more meaningful once a real workload exists to consume a
  synced value.

## Consequences

### Positive

- The next phase has no external dependency beyond what already exists (Helm, the
  already-installed Argo CD control plane).
- It directly produces the artifact ADR-0006 already committed this project to.
- The postponement is explicit and time-boxed by this ADR's own existence, not an
  open-ended slip.

### Negative

- Human-identity/SSO for Argo CD remains unimplemented for at least one more phase.
- The TAD's roadmap numbering for SSO is deferred until a future ADR names the phase
  that finally picks it up.

## Security and Cost Implications

No AWS cost impact (local `kind` cluster only). Security posture is neutral-to-positive
in the short term: the current Argo CD `admin`-only access model is unchanged either way,
and this postponement does not weaken any control already in place — it defers adding a
new one.

## Validation Method

The TAD's Delivery Roadmap and Architecture Decisions table both reference this ADR's
number for the Keycloak/SSO postponement (`docs/architecture/technical-architecture.md`).
The eventual SSO-focused ADR (0009 or later, whenever authorized) must reference this one
as its predecessor. Deferred capabilities are named explicitly, not silently dropped: a
Keycloak dev-mode instance, direct-OIDC-to-Keycloak configuration in `argocd-cm`,
`argocd-rbac-cm` group-to-role mapping, and a documented break-glass procedure.
