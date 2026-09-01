# ADR-0002: Environment topology

**Status:** Accepted
**Date:** 2026-08-31

## Context

The project must support separate `management`, `staging`, and `prod`
environments, both locally and on AWS, without incurring cost by default
and without claiming multi-environment behavior that is not actually
exercised. A common failure mode in multi-environment GitOps platforms is
that only one environment ever becomes fully materialized, while the
others silently depend on an undocumented mechanism.

## Decision

Model three environments consistently across both layers, with a clear
role split:

- **`management`** hosts control-plane-exclusive components only: Argo
  CD; Keycloak, for the local lab only; and an ESO instance *if*
  control-plane components need to reconcile a secret (e.g. Argo CD's
  own OIDC client secret). It never receives application workloads.
- **`staging`** hosts application workloads, its own ESO instance, the
  runtime add-ons those workloads need, its own Pod Identity association
  for that ESO instance, and its own namespace-scoped `SecretStore`s and
  IAM roles.
- **`prod`** hosts application workloads and the same per-cluster
  shape as `staging` — its own ESO instance, runtime add-ons, Pod
  Identity association, `SecretStore`s, and IAM roles — kept fully
  separate from staging's.

**No ESO controller instance is shared across clusters.** Each of the
three clusters that needs to create Kubernetes `Secret`s runs its own
ESO instance, authenticated via its own Pod Identity association, with
its own `SecretStore`s and IAM roles (see ADR-0004). This distinguishes
three categories cleanly: **control-plane add-ons** (`management` only:
Argo CD, Keycloak, and, if needed, ESO for control-plane secrets),
**workload-cluster runtime add-ons** (`staging`/`prod`: each cluster's
own ESO instance and any other add-on a workload needs), and
**application workloads** (`staging`/`prod` only, never `management`).

### Local: two lab profiles

- **`lab-lite`** — one `kind` cluster, namespaces simulating the three
  environments. Lower fidelity, lower resource cost; the default for
  day-to-day iteration.
- **`lab-multicluster`** — three separate `kind` clusters, one per
  environment. Higher fidelity, higher resource cost; used deliberately
  when cross-cluster fidelity matters, not by default.

### AWS: prepared, not permanent

- Terraform prepares one VPC and one EKS cluster root per environment
  (`management`, `staging`, `prod`), sharing the same reusable modules.
- **No AWS cluster exists by default.** Preparing the Terraform roots
  does not create anything; `apply` requires a fresh, explicit,
  per-environment authorization.
- When AWS is eventually authorized, **staging is the first candidate**
  for a temporary environment. **Production remains plan-only** until a
  separate, explicit authorization is given for it.

## Alternatives Considered

- **Single shared "environment" with tags/labels only**: rejected — does
  not give a credible demonstration of environment isolation.
- **Always running three full local `kind` clusters**: rejected as the
  only option — reserved as `lab-multicluster` for when higher fidelity
  is worth the resource cost.
- **Three permanently running EKS clusters in AWS for the lab**: rejected
  — see the TAD's "Costs and FinOps" section.
- **Letting `management` also host demo workloads "for convenience"**:
  rejected — mixing platform add-ons and application workloads in the
  same environment undermines the trust-boundary separation the rest of
  the design depends on (see ADR-0003).
- **A single, shared ESO controller instance reconciling secrets for all
  three clusters**: rejected — a multi-cluster topology means each
  cluster is where its own Kubernetes `Secret`s are actually created;
  a shared controller would need broad, cross-cluster reach and would
  reintroduce the over-privileged-controller risk ADR-0004 is built to
  avoid.

## Consequences

### Positive

- A consistent mental model of "three environments, one role split"
  across local and AWS.
- `lab-lite` keeps day-to-day iteration cheap; `lab-multicluster` is
  available when cross-cluster fidelity actually matters.
- No standing AWS cost from environment topology alone.

### Negative

- Two lab profiles to maintain instead of one.
- Terraform must support three environment roots from early on, adding
  upfront structure before there is production traffic to justify it.

## Security and Cost Implications

No AWS cost is introduced by this decision alone — no environment is
applied by default. See the TAD's "Costs and FinOps" for control-plane
pricing once staging is authorized.

## Validation Method

An automated test (Phase 2+) must actually exercise environment
separation (e.g., a change reconciled in staging must not appear in
production without the promotion step, and no workload is ever generated
for `management`) before "environment separation works" is upgraded from
`PROPOSED` to `VERIFIED`.
