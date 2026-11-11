# ADR-0015: Hub-and-spoke environment model (`management` + `dev`/`uat`/`prod`)

**Status:** Accepted
**Date:** 2026-11-10

Amends [ADR-0002](0002-environment-topology.md). Everything ADR-0002
decides that this ADR does not explicitly change remains in force: no
AWS cluster runs by default, `management` never receives application
workloads, no ESO controller instance is shared across clusters, and
`lab-lite` stays the default local profile.

## Context

ADR-0002 modeled one control-plane environment (`management`) and two
workload environments (`staging`, `prod`). Every implemented phase so
far (2.3–3.3.5) materializes exactly those two workload environments,
locally as namespaces of a single `kind` cluster and on AWS as
offline-validated Terraform/GitOps profiles.

Two gaps remain in that model:

1. **There is no environment for unreviewed, fast-moving change.** With
   only `staging` and `prod`, `staging` has to serve both as the place
   where every merge lands automatically and as the last
   production-like gate before promotion. Those are different jobs: one
   wants high change velocity and tolerates breakage, the other wants
   stability and production parity. Combining them makes `staging`
   either too unstable to trust as a gate, or too guarded to be useful
   for integration.
2. **The control-plane/workload-plane split is described but never
   exercised across clusters.** `lab-multicluster` (Phase 2.7) is
   reserved but not built, so Argo CD has never had to register,
   authenticate to, and be restricted against a *remote* cluster. That
   is the riskiest part of the GitOps trust model (R-03, R-05) and it
   is untested.

The AWS shape has a related gap: ADR-0002 prepares one VPC/EKS root per
environment but does not say whether environments share an AWS account.
A shared account makes IAM the only isolation boundary between
environments, which is a well-documented source of blast-radius and
cost-attribution problems in multi-environment platforms.

## Decision

Adopt an explicit **hub-and-spoke** model with one hub and three spokes:

| Role | Environment | Hosts | Application workloads | Promotion into it |
|---|---|---|---|---|
| Hub | `management` | Argo CD (the only Argo CD), control-plane add-ons, and — from Phase 6.1 — the aggregation point for spoke telemetry | **Never** | — |
| Spoke | `dev` | Its own runtime add-ons (own ESO, own identity associations) | Yes | Automatic on merge to `main` |
| Spoke | `uat` | Same per-cluster shape as `dev`, fully separate | Yes | Reviewed PR |
| Spoke | `prod` | Same per-cluster shape, fully separate | Yes | Reviewed PR **plus** the `AppProject`/RBAC/least-privilege-credential controls of ADR-0003 |

- **`uat` replaces `staging`** as the production-like gate, and `prod`
  replaces the code's earlier `production` name. The rename is
  sequenced inside Phase 2.7: 2.7.1 renames the local lab and adds the
  `dev` namespace (implemented), 2.7.2 renames the aws-eks profile and
  Terraform, and 2.7.3–2.7.4 introduce the remote spokes.
- **Hub-to-spoke direction is pull-from-Git, push-to-cluster by the hub
  only.** The hub's Argo CD is the only component holding spoke
  credentials; spokes never hold credentials for the hub or for each
  other. Each spoke registration uses a dedicated, least-privilege
  identity scoped to that spoke (closing R-05 in the local lab first).
- **Spokes are generated, not hand-listed.** The `ApplicationSet` moves
  from a fixed list generator to a cluster generator keyed on spoke
  labels (`platform.environment=dev|uat|prod`), so adding or removing a
  spoke is a cluster-registration change, not an `ApplicationSet` edit.
  An unknown or missing label fails closed (no Application is
  generated), consistent with the existing profile behavior.

### Local

- **`lab-lite`** stays the default: one `kind` cluster, `dev`/`uat`/`prod`
  simulated as namespaces.
- **`lab-multicluster`** becomes the hub-and-spoke profile: one `kind`
  cluster for `management` plus one per spoke. `prod` is **optional**
  (opt-in flag) so the routine profile is hub + `dev` + `uat`, keeping
  local resource use bounded (R-10).

### AWS

- **Target design: one AWS account per environment** (`management`,
  `dev`, `uat`, `prod`) under one AWS Organization, with
  organization-level guardrails (service control policies, centralized
  threat detection and configuration recording, budgets) defined in
  Terraform. The account boundary, not IAM alone, is the isolation
  boundary between environments.
- **First real deployment: a single sandbox account**, with hub and one
  spoke as separate clusters in it, created and destroyed in one
  authorized session. The multi-account design stays plan-only until a
  separate authorization. This keeps the first real cost to a few
  hours of two control planes and minimal nodes.
- No AWS resource is created by this ADR. Every `apply` remains subject
  to the safety gates in `AGENTS.md`.

## Alternatives Considered

| Option | For | Against | Verdict |
|---|---|---|---|
| **Hub + `dev`/`uat`/`prod` spokes** | Separates integration from the release gate; exercises remote-cluster trust; matches the promotion ladder most teams already reason about | One more environment to keep reconciled; heavier local multicluster profile | **SELECTED** |
| Keep hub + `staging`/`prod` (ADR-0002 as is) | No rename; fewer clusters | `staging` keeps two conflicting jobs; no auto-deploy target separate from the gate | **REJECTED** |
| Add `dev` but keep the name `staging` instead of `uat` | Avoids the rename | `staging` and `uat` mean different things in different teams; `uat` states the gate's purpose explicitly | **REJECTED** |
| One Argo CD per cluster (no hub) | No cross-cluster credentials at all | Three control planes to operate and upgrade; no single view of drift; promotion logic duplicated per cluster | **REJECTED** |
| Single AWS account, environments separated by IAM only | Simplest, cheapest to design | IAM becomes the only blast-radius boundary; weaker cost attribution; harder guardrails per environment | **REJECTED** as the target design; **KEPT** only for the first sandbox deployment |

## Consequences

### Positive

- `dev` absorbs every merge automatically, so `uat` can be held to a
  production-like standard.
- The hub's remote-cluster credentials, `AppProject` destinations, and
  RBAC are exercised for real in `lab-multicluster` before any AWS
  cluster exists.
- The AWS design gains account-level isolation and a natural place for
  organization-wide guardrails and per-environment cost tracking.

### Negative and residual risk

- The `staging` → `uat` rename touches namespaces, values files, ESO
  release names, and lifecycle tests; until Phase 2.7 lands, the code
  still says `staging` while this ADR says `uat`. The TAD's evidence
  table tracks that gap explicitly.
- The hub becomes the single most sensitive component: it holds
  credentials for every spoke. R-03 (compromised Argo CD) gains weight
  and stays `Open`.
- `lab-multicluster` with all four clusters may exceed a laptop's
  Docker resources; `prod` being opt-in mitigates, not removes, this.

## Security and Cost Implications

- **Security:** spoke credentials live only in the hub, one identity per
  spoke, no shared credential across spokes; spokes are never granted
  access to the hub. In AWS, account boundaries add a second isolation
  layer under IAM.
- **Cost:** local profiles have no AWS service charges. The AWS
  multi-account design is plan-only (USD 0). The first sandbox
  deployment, when separately authorized, is bounded to two control
  planes for a few hours plus minimal spot nodes; the TAD's "Costs and
  FinOps" table carries the estimate as `INFERRED` until measured.

## Validation Method

- Phase 2.7: a `lab-multicluster` lifecycle test proves the hub
  registers `dev` and `uat` (and `prod` when opted in) with distinct
  identities, that the cluster generator produces exactly one
  Application per labeled spoke and none for the hub or for an
  unlabeled cluster, and that a spoke credential cannot act on another
  spoke.
- Phase 3.4: `terraform test` for the multi-account roots, offline, plus
  `terraform apply` against a local AWS emulator for the resource types
  it supports; no real AWS apply without separate authorization.
- Until those phases land, every capability in this ADR is tracked as
  `PROPOSED` in the TAD's evidence table.
