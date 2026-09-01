# Technical Architecture Document — eks-gitops-platform-project

## Document Control

| Field | Value |
|---|---|
| Document | eks-gitops-platform-project Technical Architecture |
| Version | 0.5.0 |
| Status | Architecture baseline |
| Phase | Phase 2.1 — Local tooling and kind foundation (implemented) |
| Last updated | 2026-08-31 |

This document is the **single, authoritative source of truth** for the
project's architecture: scope, principles, topology, control plane,
identity, secrets, security, risks, evidence, and roadmap. Diagrams are
inline Mermaid, versioned as part of this file; a standalone draw.io
diagram and a polished DOCX export are derived artifacts generated from
this document later (Phase 7), never an independent source to keep in
sync.

Architectural reasoning here stands on this project's own requirements
and on general, well-documented GitOps/Kubernetes/AWS engineering risks
— never on a claim that a specific external system, prior organization,
or private document informed a decision (see `AGENTS.md`).

## Executive Summary

`eks-gitops-platform-project` is a greenfield, portfolio-quality GitOps
platform for AWS EKS, built from scratch in small, reviewable phases. It
demonstrates: reproducible AWS/EKS infrastructure via Terraform; workload
identity without static credentials (EKS Pod Identity, IRSA as
compatibility); secrets that never enter Git (External Secrets Operator
+ AWS Secrets Manager, run per cluster, under a layered isolation model);
Argo CD reconciling a closed set of environments through
`ApplicationSet`; and production promotion gated by a reviewed PR
**plus** runtime trust boundaries (`AppProject`, RBAC, least-privilege
credentials) — the PR alone is treated as necessary, not sufficient.

As of this version, **nothing has been implemented**. This document
describes the target architecture and the decisions behind it; the
[evidence table](#evidence-and-implementation-status) states plainly
that no runtime capability is `VERIFIED` yet. An `Accepted` ADR below
records an approved decision — it does not mean that decision has been
implemented.

## Scope and Non-Goals

**In scope:** a local, reproducible `kind`-based lab; a target AWS/EKS
Terraform substrate (plan-only until authorized); Argo CD +
`ApplicationSet` with an explicit trust model; a standard workload
contract; human identity (IAM Identity Center, Keycloak for the local
lab) and workload identity (Pod Identity, IRSA); secrets management with
a layered, per-cluster isolation model; PR-gated environment promotion.

**Non-goals:** a general-purpose internal-developer-portal UI; support
for cloud providers other than AWS; a self-service infrastructure
catalog in the MVP (Crossplane or equivalent — deferred, see ADR-0001);
Progressive Delivery as the primary production gate; three permanently
running EKS clusters; generating application workloads for the
`management` cluster; deciding Argo CD's production AWS identity
provider ahead of Phase 3/4 (see "Human Identity and SSO").

## Architecture Principles

1. **A single Git repository is the desired-state source of truth** for
   everything Argo CD reconciles.
2. **Application and infrastructure concerns are separated** — the
   standard workload chart never provisions cloud infrastructure.
3. **Identity contracts between independently evolving systems are
   tested, never assumed.** The (cluster, namespace, `ServiceAccount`)
   tuple that Terraform and the workload chart must agree on is covered
   by an automated contract test before it is trusted.
4. **Every required CI check blocks the merge it protects** — no
   required check is ever configured to continue past a failure.
5. **A reviewed pull request is necessary, but not sufficient, for
   production promotion** — it is paired with `AppProject` boundaries,
   Argo CD RBAC, and least-privilege cluster credentials.
6. **Pinning applies to what is consumed, not to the desired-state
   branch itself** — `main` may be tracked continuously because it is
   protected by review; external dependencies are pinned immutably.
7. **No control-plane component's identity is shared across clusters
   for convenience** — each cluster that needs to act on AWS (including
   each cluster's ESO instance) has its own scoped identity.
8. **Confidence is labeled honestly** — a capability described only in
   documentation is never `VERIFIED`.

## System Context

```mermaid
flowchart TB
    subgraph Human["Human Access"]
        Users["Human users<br/>(admin / developer / auditor)"]
    end

    IDC["IAM Identity Center<br/>(human AWS/EKS access)"]
    Git["Git repository<br/>(protected branch: main)"]

    subgraph Mgmt["Management cluster (control plane)"]
        Argo["Argo CD"]
        Keycloak["Keycloak<br/>(local lab IdP)"]
        ESOMgmt["ESO<br/>(control-plane secrets only)"]
    end

    subgraph Staging["Staging cluster (workload plane)"]
        WLStaging["Application workloads"]
        ESOStaging["ESO<br/>(staging secrets)"]
    end

    subgraph Prod["Production cluster (workload plane)"]
        WLProd["Application workloads"]
        ESOProd["ESO<br/>(production secrets)"]
    end

    SM["AWS Secrets Manager"]

    Users -->|"SSO"| IDC
    Users -->|"OIDC, local lab"| Keycloak
    IDC -->|"access entries"| Mgmt
    IDC -->|"access entries"| Staging
    IDC -->|"access entries"| Prod
    Git -->|"desired state,<br/>pulled by Argo CD"| Argo
    Argo -->|"reconciles"| Staging
    Argo -->|"reconciles"| Prod
    ESOMgmt --> SM
    ESOStaging --> SM
    ESOProd --> SM
```

Argo CD **pulls** the desired state from Git and reconciles it toward
`staging` and `prod` — Git is a source Argo CD reads, not something Argo
CD reconciles. `management` is the control plane only; it is never a
workload plane. Every cluster that creates Kubernetes `Secret`s runs its
**own** ESO instance against AWS Secrets Manager — none is shared. See
"Cluster and Environment Topology."

## Cluster and Environment Topology

| Environment | Role | Control-plane add-ons | Workload-cluster runtime add-ons | Application workloads |
|---|---|---|---|---|
| `management` | Control plane | Argo CD; Keycloak (local lab only); ESO, if a control-plane component needs a secret (e.g. Argo CD's OIDC client secret) | — | **No** |
| `staging` | Workload plane | — | Its own ESO instance, own Pod Identity association, own namespace-scoped `SecretStore`s and IAM roles | Yes — auto-reconciled |
| `prod` | Workload plane | — | Its own ESO instance, own Pod Identity association, own namespace-scoped `SecretStore`s and IAM roles, fully separate from staging | Yes — PR-promoted only |

**No ESO controller instance is shared across clusters.** This
distinguishes three categories: **control-plane add-ons** (`management`
only), **workload-cluster runtime add-ons** (`staging`/`prod`, including
each cluster's own ESO), and **application workloads** (`staging`/`prod`
only, never `management`).

**Local lab profiles:**
- `lab-lite` — **implemented as of Phase 2.1**: one `kind` cluster
  (`kindest/node:v1.36.4`, pinned by digest), single control-plane node.
  As of Phase 2.1 it is only the cluster itself — `staging`/`production`
  namespaces, Argo CD, and any workload are added in later Phase 2
  increments (2.2/2.3), never created imperatively (see "GitOps Control
  Plane" for the imperative/declarative boundary). Namespace-level
  environment simulation validates GitOps generation, RBAC, destination
  restrictions, and reconciliation logic — it does **not** prove real
  cluster-level isolation.
- `lab-multicluster` — documented, not created. Three separate `kind`
  clusters, one per environment; reserved for deliberate, manual
  execution once `lab-lite` passes all its criteria (Phase 2.5). Real
  `management`/`staging`/`production` cluster separation is validated
  only there.

**Local toolchain and isolation (Phase 2.1):** `kind v0.33.0` and
`kubectl v1.36.4` run from project-local, checksum-pinned binaries
(`.tools/bin/`, gitignored, installed only via `make tools-install` —
never the machine's global `kubectl`/`kind`). The cluster's kubeconfig
lives at `.local/kubeconfig` (gitignored), never merged into
`~/.kube/config` and never read from an ambient `KUBECONFIG` — every
`lab/kind/*.sh` and `tests/lab/*.sh` script passes both explicitly. This
keeps the lab isolated from any EKS context, Docker Desktop Kubernetes,
or other `kind` clusters on the same machine.

**AWS**: Terraform prepares one VPC/EKS root per environment; **no AWS
cluster exists by default**. Staging is the first candidate for a
temporary environment once authorized; production stays plan-only until
a separate authorization. No AWS cluster runs permanently for the lab.
See ADR-0002.

## GitOps Control Plane

Argo CD, running in `management`, reads the protected `main` branch of
this repository and reconciles it toward `staging` and `prod`.
`ApplicationSet` generates `Application` objects from an explicit, closed
environment list/matrix (never free text) — it **generates, it does not
authorize**. `AppProject` boundaries restrict allowed source
repositories, destination cluster/namespace pairs, and resource kinds
per trust domain. Control-plane add-ons and application workloads use
distinct GitOps boundaries — never the same `AppProject` or generator.
See ADR-0003.

**Imperative/declarative boundary across Phase 2 increments:** Phase 2.1
creates only the `kind` cluster itself — never `staging`, `production`,
`ApplicationSet`, `AppProject`, or any Argo CD resource. Phase 2.2's
bootstrap is a narrow, explicit exception: it may imperatively create
only what installing the GitOps controller itself requires (the Argo CD
namespace and the pinned Argo CD Helm release) — **it does not create the
root/bootstrap `Application`, any `AppProject`, or any `ApplicationSet`**;
those, along with `staging`/`production` and every environment policy,
are explicitly deferred to Phase 2.3 and created and reconciled
**declaratively** by Argo CD once it exists — no imperative script owns a
resource that GitOps should reconcile from there on.

### Local Lab Argo CD Bootstrap (Phase 2.2)

`lab/argocd/*.sh` (backing the `make argocd-*` targets) installs Argo CD
into the Phase 2.1 `lab-lite` `kind` cluster, entirely offline once the
chart is fetched, and entirely isolated to the project-local toolchain
and kubeconfig — the same isolation discipline as Phase 2.1.

- **Chart:** `argo-helm/argo-cd` `10.4.2` (app version `v3.5.2`), fetched
  once as an immutable GitHub Release `.tgz` asset and SHA256-pinned in
  `scripts/argocd/_lib.sh` — never `helm repo add`, never a floating
  version. `make argocd-chart-fetch` is the only target permitted to
  download it; every other target requires it already present and
  checksum-verified.
- **Tooling:** Helm `v4.2.4`, installed the same way as `kind`/`kubectl`
  in Phase 2.1 — a pinned, checksum-verified download into
  `.tools/bin/helm` — except Helm ships as a `tar.gz` archive, so
  `scripts/lab/install-tools.sh` extracts exactly one validated,
  non-symlink, regular-file archive member before verifying and
  installing it.
- **Images:** every rendered image reference is digest-pinned
  (`repository:tag@sha256:digest`) — `quay.io/argoproj/argocd:v3.5.2` and
  `ecr-public.aws.com/docker/library/redis:8.6.4-alpine`, each verified
  against the registry's own `Docker-Content-Digest` at pin time.
  `dex` and `notifications-controller` are disabled; `make argocd-render`
  proves both are absent from the render and that no tag-only image
  exists.
- **Values contract:** `lab/argocd/values-lab.yaml` is the single,
  explicit source of every override — one replica per component,
  `ClusterIP`-only `server` service, ingress disabled, explicit
  CPU/memory requests and limits on every rendered container and init
  container (including the `copyutil` init container and the
  `redis-secret-init` pre-install hook `Job`), and `crds.keep: true` so
  Argo CD's CRDs survive an `uninstall`.
- **Idempotency, proven not assumed:** `make argocd-install` is
  fail-closed — absent → installs; an exact match against the pinned
  chart, values fingerprint, and live manifest → a true no-op (no `helm
  upgrade` call at all); any drift in any of those → refuses to
  reconcile automatically and fails closed. `make argocd-test-lifecycle`
  exercises install → install (asserting the Helm release revision, the
  live manifest checksum, and every managed workload's
  `.metadata.generation` are byte-identical — proving no rollout
  occurred) → uninstall (asserting the exact three Argo CD CRDs are
  retained and still schema-compatible via `kubectl diff`, and that no
  unexpected `*.argoproj.io` CRD exists) → uninstall no-op → a
  restoration install using those retained CRDs, leaving Argo CD
  installed and healthy at the end.
- **Namespace ownership:** the `argocd` namespace carries a dedicated
  `eks-gitops-lab-lite.local/owner=argocd-bootstrap` label (not the
  generic `app.kubernetes.io/managed-by`); `make argocd-uninstall` only
  ever deletes it when this bootstrap owns it and an exhaustive
  namespaced-resource inventory (every `kubectl api-resources
  --verbs=list --namespaced` type, not just `kubectl get all`) shows
  nothing beyond the two objects Kubernetes itself always creates.
- **Admin access:** the initial-admin `Secret`'s password is decoded
  manually (`kubectl ... -o jsonpath='{.data.password}' | base64 -D` on
  macOS) — never scripted, logged, or written to any evidence file — and
  is expected to be deleted once a replacement auth method is in place.
  `make argocd-port-forward` exposes the UI/API at
  `https://localhost:8443` in the foreground only.

## Application Delivery and Promotion

```mermaid
flowchart TB
    Dev["Developer change"] --> PR1["Validation PR<br/>(CI: lint, policy,<br/>secret scan)"]
    PR1 --> Main["Protected branch: main"]
    Main --> ASGen["ApplicationSet<br/>(generates Applications)"]
    ASGen -.->|"generates only,<br/>does not approve"| Note["Approval = PR gate<br/>+ AppProject / RBAC"]
    ASGen --> StagingSync["Automatic staging<br/>reconciliation"]
    StagingSync --> PromPR["Explicit production<br/>promotion PR"]
    PromPR --> ProdSync["Production<br/>reconciliation"]
    ProdSync -.->|"if rollback needed"| Revert["Git revert"]
    Revert --> Main
```

Staging reconciles automatically from `main`. Production is promoted
only through a **separate, explicit PR** that bumps a pinned
external-dependency value (chart version, image digest) — never a direct
commit. Rollback is a Git revert of the promotion commit, reconciled the
same way. The PR gate is necessary but not sufficient: it is paired with
the `AppProject`/RBAC/least-privilege-credential controls in "Security
and Trust Boundaries." See ADR-0003.

## Workload Deployment Contract

One standard Helm chart renders every workload: `Deployment`/`Service`,
an explicit `ServiceAccount` `identityMode` (`podIdentity` / `irsa` /
`none` — see "Workload Identity"), startup/readiness/liveness probes,
resource requests/limits, an HPA that does not fight a static replica
count, a `PodDisruptionBudget`, topology-spread/anti-affinity, graceful
termination, `NetworkPolicy`, optional `Ingress`, an optional
metrics/`ServiceMonitor` interface, and digest-pinned images. The chart
never provisions cloud infrastructure and fails clearly on invalid
values — every documented field is backed by a template that reads it.
See ADR-0006.

## Human Identity and SSO

- **Human → AWS/EKS:** AWS IAM Identity Center; EKS access entries mapped
  to groups. This is settled.
- **Human → Argo CD, local lab:** Keycloak, direct OIDC — no Dex broker
  unless a concrete multi-connector need appears later. **Keycloak is
  the reproducible identity provider for the local lab only; this
  document does not assert it will be the production identity
  provider.**
- **Human → Argo CD, production AWS:** the identity provider is
  **`UNKNOWN`**, pending an explicit decision in Phase 3/4. The local
  lab's job is to prove the OIDC/RBAC mechanism (authenticate, map to a
  role, enforce that role) — not to pre-select a production IdP.
- Roles: platform administrator, application developer (scoped to owned
  namespaces), read-only auditor. `admin` is a bootstrap/break-glass
  fallback, not the standing path once OIDC is configured.
- Bootstrap: the Keycloak↔Argo CD OIDC secret is generated locally,
  stored only as an ephemeral in-cluster `Secret`, never written to Git.
  In AWS, Argo CD may start without SSO; the `management`-cluster ESO
  instance is installed before OIDC is finalized; the secret then lives
  in Secrets Manager. See ADR-0005.

## Workload Identity

```mermaid
flowchart LR
    subgraph WorkloadPath["Workload path"]
        Pod["Workload Pod"] --> PIAgent["EKS Pod Identity"]
        PIAgent --> IAMRole["IAM role"]
        IAMRole --> AWSService["AWS service"]
    end

    subgraph SecretsPath["Secrets path"]
        ESO["ESO controller<br/>(per cluster)"] --> PIAgent2["EKS Pod Identity"]
        PIAgent2 --> TenantRole["Namespace/tenant role"]
        TenantRole --> SecretsMgr["AWS Secrets Manager"]
        ESO --> K8sSecret["Kubernetes Secret"]
        K8sSecret --> Pod
    end

    subgraph Compat["Compatibility path only"]
        Pod2["Workload Pod<br/>(IRSA-only add-on)"] -.->|"OIDC trust policy +<br/>role-arn annotation"| IRSARole["IAM role via IRSA"]
    end
```

EKS Pod Identity is the default: no `eks.amazonaws.com/role-arn`
annotation, requires the Pod Identity Agent, bound via a
Terraform-managed (cluster, namespace, `ServiceAccount`) association.
IRSA is an explicit compatibility path only — OIDC provider, trust
policy, and the annotation — never a silent fallback and never described
as the same mechanism as Pod Identity. The contract that must be tested
is the (cluster, namespace, `ServiceAccount`) tuple; `kind` validates its
shape only — it cannot prove Pod Identity itself. See ADR-0004.

## Secrets Management

External Secrets Operator runs as a **separate instance in every
cluster** that needs to create Kubernetes `Secret`s — `management`
(control-plane secrets only), `staging`, and `prod`. **No ESO controller
instance is shared across clusters.** Each instance reconciles secrets
from AWS Secrets Manager under a layered model: IAM least privilege,
Kubernetes RBAC, that cluster's own ESO controller identity (via its own
Pod Identity association), and — where feasible — per-namespace/tenant
assumable roles scoped to that cluster. A namespace-scoped `SecretStore`
is the default in every cluster, referencing that cluster's own scoped
role; it is **not by itself the security boundary** — real isolation is
the combination of all layers above, evaluated per cluster.
`ClusterSecretStore` requires a separate, explicit decision, per cluster
if ever adopted. See ADR-0004.

## Terraform and Bootstrap Boundary

Terraform provisions AWS infrastructure (VPC, EKS, IAM baseline, KMS,
Pod Identity associations for every cluster's workloads and ESO
instance) and Argo CD's initial bootstrap installation only. After
bootstrap, Argo CD manages its own declarative configuration — Terraform
does not keep patching it. The OIDC-secret bootstrap ordering (Argo CD
may start without SSO → the `management`-cluster ESO instance installed
→ OIDC finalized) and its open seeding question are described in
ADR-0005; Terraform must never store a secret's plaintext value in state.
See ADR-0001 and ADR-0005.

## Security and Trust Boundaries

- `AppProject` per trust domain; Argo CD RBAC; a restricted set of
  principals allowed to modify `ApplicationSet` definitions; a documented
  sync/prune policy; least-privilege Argo CD cluster credentials.
- **Explicit threat-model statement:** a compromised Argo CD controller,
  or an over-privileged/admin-level cluster credential, can mutate a
  cluster directly regardless of branch protection. This is why the PR
  gate (ADR-0003) is paired with the runtime controls above, not treated
  as sufficient alone.
- Secrets isolation depends on the layered, per-cluster model in
  "Secrets Management" — a namespace-scoped `SecretStore` is not a
  boundary by itself, and no ESO identity is shared across clusters.
- No long-lived AWS access keys are permitted anywhere in this
  repository (checked by `scripts/validate/check-secrets.sh`, within its
  documented pattern coverage).

## Observability and Operations

`NOT IMPLEMENTED`. The standard chart reserves a metrics/`ServiceMonitor`
interface without forcing a Prometheus dependency. An observability
stack, runbooks, and failure drills are Phase 6 scope.

## Availability and Recovery

`NOT IMPLEMENTED`. Backup/DR boundaries and single-point-of-failure
analysis for the GitOps delivery path (including the bootstrap-cycle
risk in the table below) are Phase 6 scope.

## Costs and FinOps

| Item | Cost | Status |
|---|---|---|
| Local lab (`lab-lite` or `lab-multicluster`) | No AWS service charges — runs on local Docker | `PROPOSED` — neither profile exists yet |
| Terraform plan-only | No AWS service charges | `PROPOSED` as a standing rule |
| One EKS cluster, standard support, control plane only | ≈US$0.10/hour | `INFERRED` — public AWS pricing at time of writing, not re-verified live |
| Three EKS control planes running continuously | ≈US$219/month, before nodes/NAT/storage/transfer | `INFERRED` — same caveat; why this project never runs three permanent clusters |

"No AWS service charges" means no billed AWS resource consumption — it
is not a claim of zero cost in every sense (local compute/electricity is
not counted). All figures must be re-verified against current AWS
pricing before any real deployment. **No AWS resource is created without
a fresh, explicit authorization.**

## Architecture Decisions

| ADR | Decision | Status |
|---|---|---|
| [ADR-0001](../adr/0001-platform-scope-and-boundaries.md) | Platform scope and repository boundaries | Accepted |
| [ADR-0002](../adr/0002-environment-topology.md) | Environment topology | Accepted |
| [ADR-0003](../adr/0003-gitops-control-plane-and-promotion.md) | GitOps control plane and promotion | Accepted |
| [ADR-0004](../adr/0004-workload-identity-and-secrets.md) | Workload identity and secrets | Accepted |
| [ADR-0005](../adr/0005-sso-bootstrap-and-cluster-access.md) | SSO, bootstrap, and cluster access | Accepted |
| [ADR-0006](../adr/0006-standard-workload-contract.md) | Standard workload contract | Accepted |

Each ADR above records an **approved decision**, not an implemented one
— every capability it describes is tracked honestly in "Evidence and
Implementation Status" below.

## Risks and Open Questions

| ID | Risk | Impact | Mitigation | Status |
|---|---|---|---|---|
| R-01 | The (cluster, namespace, `ServiceAccount`) Pod Identity contract is untested against real EKS | High | Shape-test in `kind`; positive/negative test against a temporary, authorized EKS cluster (ADR-0004) | Open |
| R-02 | Any cluster's ESO controller identity could be over-privileged, making that cluster's namespace-scoped `SecretStore`s a nominal boundary only — evaluated per cluster and per tenant | High | Per-cluster, per-namespace/tenant assumable roles; IAM least privilege; no ESO identity shared across clusters (ADR-0002, ADR-0004) | Open |
| R-03 | A compromised Argo CD controller or admin-level cluster credential can mutate a cluster regardless of branch protection | High | `AppProject`, Argo CD RBAC, least-privilege cluster credentials (ADR-0003) | Open |
| R-04 | Bootstrap cycle between Argo CD, the `management`-cluster ESO instance, and the OIDC client secret | Medium | Documented ordering; OIDC-secret seeding mechanism explicitly `UNKNOWN` pending Phase 4 (ADR-0005) | Open |
| R-05 | Remote EKS cluster access/credentials for Argo CD not yet designed | Medium | Explicitly deferred to Phase 3/4 with a least-privilege requirement stated up front (ADR-0005) | Open |
| R-06 | No CI or branch protection exists yet — the PR-gate design is unenforced | High (if a mutating change happened today) | No remote is configured during this phase; tracked for the phase that introduces one | Open |
| R-07 | AWS costs could be incurred without authorization | High if it happened | Standing rule: no `apply` without fresh, explicit, scoped authorization | Mitigated by policy, not tooling yet |
| R-08 | TAD/code drift as implementation begins | Medium | TAD updated in the same PR as any architecture change (`AGENTS.md`) | Open |
| R-09 | Secret and confidentiality-term scanning is pattern-based, not exhaustive | Medium | Documented explicitly in each script; never presented as a complete scanner | Accepted limitation |
| R-10 | `lab-multicluster` may be too resource-intensive for routine local iteration | Low | `lab-lite` is the default; `lab-multicluster` used deliberately | Open |

## Evidence and Implementation Status

| Capability | Status | Evidence required |
|---|---|---|
| Repository foundation (TAD, ADRs, validation scripts) | `CODE-CONFIRMED` | Files exist and pass `make validate` |
| Local documentation validation (`make validate`) | `VERIFIED`, within each script's documented pattern coverage | Executed with a reproducible result during this phase |
| Target architecture described in this document | `PROPOSED` | Design only; nothing deployed |
| Local lab tooling (`make tools-check`/`tools-install`, `lab/kind/*.sh`) | `VERIFIED` | Executed in this phase: `make tools-install` downloaded and checksum-verified `kind v0.33.0`/`kubectl v1.36.4` into `.tools/bin/`; `make tools-check` confirmed them read-only |
| `lab-lite` cluster: creation, idempotency, teardown, identity match | `VERIFIED`, scoped to exactly what was exercised (cluster lifecycle and identity — not Argo CD/workloads, which remain `NOT IMPLEMENTED`) | `make lab-test-lifecycle` proved create→create(no-op)→destroy→destroy(no-op); the persistent cluster was then created and confirmed: server `v1.36.4` exactly, node image digest matches the pin, node `Ready`, reachable only via `.local/kubeconfig`, no `staging`/`production`/`argocd` namespace present |
| `lab-multicluster` | `NOT IMPLEMENTED` | Reserved for Phase 2.5, not created |
| Argo CD control-plane bootstrap in `lab-lite` (`make argocd-*`) | `VERIFIED`, scoped to exactly what was exercised (Argo CD's own install/uninstall/upgrade lifecycle — not `ApplicationSet`/`Application` reconciliation behavior, which remains `NOT IMPLEMENTED` until Phase 2.3) | `make argocd-chart-fetch` downloaded and checksum-verified `argo-cd-10.4.2.tgz`; `make argocd-render` confirmed all 7 rendered image occurrences (2 distinct images) are digest-pinned and dex/notifications are absent; `make argocd-test-lifecycle` proved install→install(true no-op: Helm revision, live-manifest sha256, and every managed workload's `.metadata.generation` byte-identical)→uninstall(exactly the 3 pinned CRDs retained and `kubectl diff`-compatible)→uninstall(no-op)→restoration install using those retained CRDs, ending installed and healthy; a further two `make argocd-install` runs confirmed persistence (second run a true no-op) |
| Argo CD reconciliation / `ApplicationSet` behavior | `NOT IMPLEMENTED` | No `Application`/`ApplicationSet`/`AppProject` object exists; Phase 2.2 installs only the Argo CD control plane itself |
| EKS Pod Identity workload access | `UNKNOWN` | Requires a real, temporary, authorized EKS cluster |
| Workload-identity (cluster/namespace/ServiceAccount) contract | `NOT IMPLEMENTED` | No contract test exists |
| Per-cluster External Secrets reconciliation under the layered model | `NOT IMPLEMENTED` | No cluster or ESO installation exists |
| Production PR-gated promotion | `PROPOSED` | No remote, branch protection, or `AppProject` exists yet |
| Argo CD's production AWS identity provider | `UNKNOWN` | Explicitly undecided pending Phase 3/4 (ADR-0005) |
| Crossplane-based self-service infrastructure | `OUT OF SCOPE` | Deferred past the MVP (ADR-0001) |
| Progressive Delivery as primary production gate | `OUT OF SCOPE` | Not the design (see "Application Delivery and Promotion") |
| Cost estimates in "Costs and FinOps" | `INFERRED` | Public pricing at time of writing, not re-verified live |

No capability above `NOT IMPLEMENTED`/`PROPOSED`/`UNKNOWN` is claimed as
`VERIFIED` at the runtime level anywhere in this repository.

## Delivery Roadmap

- **Phase 0 — Discovery:** complete.
- **Phase 1 — Documentation foundation:** complete.
- **Phase 2 — Local GitOps lab:**
  - **2.1 — Local tooling and `kind` foundation:** implemented (pinned `lab-lite` cluster, project-local toolchain and kubeconfig; no Argo CD, no Keycloak, no `ApplicationSet` yet).
  - **2.2 — Argo CD bootstrap:** implemented (pinned, digest-verified Argo CD control plane installed offline via Helm into `lab-lite`; fail-closed idempotent install, proven true no-op, CRD retention, and restoration; dex/notifications disabled; no `ApplicationSet`/`Application`/`AppProject` yet).
  - **2.3 — GitOps contract and demo workload:** not started.
  - **2.4 — Keycloak OIDC and Argo CD RBAC:** not started.
  - **2.5 — Multicluster profile:** not started.
  - **2.6 — Evidence and hardening:** not started.
- **Phase 3 — Terraform/EKS, plan-only:** not started.
- **Phase 4 — Identity and secrets:** not started.
- **Phase 5 — Promotion and governance:** not started.
- **Phase 6 — Hardening and operations:** not started.
- **Phase 7 — Final evidence, draw.io, and DOCX:** not started.

## Definition of Done

The project is done only when: a new engineer can launch the local lab
from documented prerequisites; `ApplicationSet` creates the intended
staging/production `Application` objects and never for `management`; the
workload-identity contract is contract-tested and EKS Pod Identity is
proven against a real, temporary, authorized EKS cluster; production
promotion requires a reviewed PR **and** the `AppProject`/RBAC/
least-privilege-credential controls; external dependencies are pinned
immutably while the desired-state branch itself is protected by review;
every cluster's ESO instance reconciles under the layered isolation model
with no secret value ever in Git; required CI checks are blocking and
green; this TAD and its six ADRs match the actual implementation; every
unverified runtime statement is labeled honestly; no
confidentiality-restricted material or its provenance is referenced
anywhere in this repository's history; and no AWS resource was created
without explicit authorization.

None of these criteria are met yet — Phase 1 delivers the architecture
baseline only; implementation begins in Phase 2.
