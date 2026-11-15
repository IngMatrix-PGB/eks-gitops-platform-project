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

### Phased implementation note (Phase 2.4)

This ADR's full vision above is not implemented in one pass. Phase 2.4
(`docs/adr/0008-standard-workload-before-sso.md`) ships only `Deployment`,
`Service`, `ServiceAccount`, and `ConfigMap`, with a Restricted-Pod-Security-
Standards-compliant default. `HorizontalPodAutoscaler`, `PodDisruptionBudget`,
`NetworkPolicy`, `Ingress`, and a `ServiceMonitor` interface remain committed
future chart capabilities — deliberately **not** schema-exposed until each has
a real template, per the Public Upstream Gap Review's findings that they
would otherwise be dead configuration in this lab: `kind`'s default CNI does
not enforce `NetworkPolicy` (WC-09); the community Ingress-NGINX controller
is being retired and Gateway API should be evaluated first, so no default
controller choice is made yet (WC-10); `ServiceMonitor` is a Prometheus
Operator CRD with no operator installed (WC-11); `HorizontalPodAutoscaler`
and `PodDisruptionBudget` need infrastructure (metrics-server, multiple
nodes/AZs, a real disruption source) this lab does not have (WC-13). Each
capability is added in a later, separately reviewed change once its
supporting infrastructure exists — this paragraph is the record that the
omission is deliberate, not an oversight.

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

## Amendment (Phase 2.8.1, 2026-11-11)

Four of the deferred capabilities are now implemented, each with a real
template, a schema entry, and a runtime test
(`make workload-test-resilience`):

- **Graceful termination:** the native `lifecycle.preStop.sleep` action
  (5 s; no shell or binary needed in the image) plus a 5 s server
  shutdown timeout. The render fails when preStop + shutdown + 5 s
  exceeds `terminationGracePeriodSeconds` (30 s).
- **`PodDisruptionBudget`:** `maxUnavailable: 1`, rendered only when
  `replicaCount` is 2 or more (today `prod` and `prod-aws`). A budget on
  one replica protects nothing, and a `minAvailable`-style budget would
  block every drain. The eviction API enforces it on a single node, so
  the lab tests it there: the first eviction is allowed, an immediate
  second one is refused with HTTP 429.
- **Topology spread:** hostname and zone, `ScheduleAnyway` by default
  so a single-node lab still schedules; `values-prod-aws.yaml` makes
  zone `DoNotSchedule`. Real distribution across nodes and zones can
  only be shown on a multi-node cluster (Phase 6.4).
- **`NetworkPolicy`:** one policy per workload, over its own pods,
  Ingress and Egress: http only from its own namespace (plus any
  namespace listed in `networkPolicy.ingressFromNamespaces`), egress
  only DNS. **WC-09 above no longer holds:** measured on this project's
  `kind` (`kindnetd v20260820`), ingress and egress policies are both
  enforced. The aws overlays keep it disabled until the EKS VPC CNI has
  network policy enabled (TAD R-14), so no policy renders where nothing
  would enforce it.

`HorizontalPodAutoscaler` (it needs metrics-server; Phase 2.8.2),
`Ingress` (WC-10) and `ServiceMonitor` (WC-11) remain deferred and are
still asserted absent by `check-standard-workload-chart`.

## Amendment (Phase 2.8.2, 2026-11-11)

`HorizontalPodAutoscaler` is implemented (`autoscaling/v2`, CPU
utilization), enabled in `prod` only (2–4 replicas, 70 %), backed by
metrics-server installed per workload cluster by script (pinned chart
3.14.0, image v0.9.0 by digest; `--kubelet-insecure-tls` in the lab
only; never on the hub; not through Argo CD, because it creates
cluster-scoped objects). The requirement that the HPA "does not fight a
statically declared replica count" is met as follows, each part measured
by `make workload-test-autoscaling`:

- A Deployment under an HPA is annotated `replicas-owner: hpa` and
  renders `replicas: minReplicas`. Argo CD ignores `spec.replicas` only
  on Deployments carrying that annotation (`jqPathExpressions` plus
  `RespectIgnoreDifferences`), so a static Deployment is still fully
  reconciled from Git: a manual scale of `dev` is reverted by self-heal.
- With the HPA above `minReplicas`, the Application stays `Synced` and
  `spec.replicas` stays at the HPA's value.
- **Hand-over of an existing Deployment.** With server-side apply, Argo
  CD stops sending a field it is told to ignore. If it was the field's
  only manager, the API server removes the field and the default of 1
  applies: measured, `prod` dropped from 2 to 1 replica on that sync.
  Rendering `minReplicas` does not prevent it. `make workload-hpa-handover`
  (run once, before the Git change that enables the HPA) gives the
  current value a second field manager. Measured with it, `spec.replicas`
  and Ready never went below 2.

`Ingress` (WC-10) and `ServiceMonitor` (WC-11) remain deferred.

## Amendment (Phase 3.4.3a, 2026-11-13): R-14 closed for the aws overlays

`terraform/envs/eks` now runs the VPC CNI with NetworkPolicy enforcement
and the metrics-server add-on. The aws overlays therefore turn both
features on: every `values-*-aws.yaml` renders the workload's
NetworkPolicy, and `values-prod-aws.yaml` renders the HPA (2–4 replicas,
70 % CPU, 300 s scale-down window). A first deploy creates the
Deployment, so no replicas hand-over is needed. `check-standard-workload-chart`'s
former R-14 guards are inverted: an aws overlay must now render the
policy with the same exact shape as the local ones, and prod-aws must
render the HPA.
