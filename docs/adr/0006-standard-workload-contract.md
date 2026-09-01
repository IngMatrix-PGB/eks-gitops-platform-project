# ADR-0006: Standard workload contract

**Status:** Accepted
**Date:** 2026-08-31

## Context

Every workload deployed by this platform should look and behave
consistently — probes, resource limits, identity, disruption budgets —
without each service team re-inventing these concerns. A well-known Helm
chart anti-pattern is "dead config": documentation describing fields no
template actually reads, letting an engineer believe a setting took
effect when it silently did nothing.

## Decision

One reusable Helm chart implements a standard contract for every
workload:

- `Deployment` and `Service`.
- `ServiceAccount` with an explicit `identityMode`: `podIdentity` (no
  invented IAM annotation), `irsa` (requires an explicit `roleArn`, fails
  clearly if missing), or `none` (see ADR-0004 for the identity model
  itself).
- Startup, readiness, and liveness probes.
- Resource requests and limits.
- An HPA that does not fight a statically declared replica count.
- A `PodDisruptionBudget`.
- Topology-spread constraints or pod anti-affinity, with documented
  trade-offs.
- Graceful termination (`terminationGracePeriodSeconds`, optional
  `preStop`).
- `NetworkPolicy`.
- Optional `Ingress`.
- An optional metrics/`ServiceMonitor` interface that does not force a
  Prometheus dependency.
- Images pinned by digest (see ADR-0003's pinning policy).

The chart **never provisions cloud infrastructure** — that is Terraform's
responsibility (ADR-0001). It must render cleanly with minimal values and
**fail clearly** on invalid combinations: every documented field is
backed by a template that actually reads it, verified by a
rendering/contract test before the field is documented.

## Alternatives Considered

- **Per-service hand-written manifests**: rejected — reintroduces
  inconsistency and makes platform-wide hardening require touching every
  service individually.
- **A chart that also provisions cloud infrastructure inline**: rejected
  — violates the application/infrastructure separation this project is
  built around.
- **An implicit or "auto-detected" identity mode**: rejected — reintroduces
  an untested, implicit contract instead of an explicit, validated one.

## Consequences

### Positive

- One surface to harden benefits every workload at once.
- A documented field is guaranteed to have an effect.
- Identity mode is always explicit and reviewable in a diff.

### Negative

- Every new required field must be added to the chart and its
  documentation together — no undocumented `values` overrides.
- Three explicit identity modes mean more template branches and test
  cases than one implicit behavior would.

## Security and Cost Implications

`NetworkPolicy` and least-privilege `ServiceAccount` defaults are
security-positive by design. No direct cost implication; indirectly
influences AWS cost through HPA/resource-limit defaults once implemented.

## Validation Method

A contract/rendering test confirming: every documented value field is
read by some template; `podIdentity` mode never sets an IAM annotation;
`irsa` mode fails clearly without an explicit `roleArn` and sets the
annotation correctly when provided; and an invalid values combination
fails rendering with a clear error. `NOT IMPLEMENTED` today; planned for
Phase 2.
