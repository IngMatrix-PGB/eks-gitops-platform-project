# eks-gitops-platform-project

A greenfield, portfolio-quality GitOps platform for AWS EKS, built from
scratch in small, reviewable phases. It demonstrates reproducible AWS/EKS
infrastructure, workload identity without static credentials, secrets
that never enter Git, Argo CD-driven environment reconciliation, and
production promotion gated by a reviewed pull request plus runtime trust
boundaries.

## Target architecture, in brief

- **Terraform** provisions AWS infrastructure; **Argo CD**, running in
  the `management` hub, pulls desired state from Git and reconciles it
  toward the workload spokes after bootstrap.
- **Hub and spoke** ([ADR-0015](docs/adr/0015-hub-and-spoke-environment-model.md)) —
  `management` is the hub and control plane only (Argo CD, Keycloak for
  the local lab); `dev`, `uat`, and `prod` are spokes, each running its
  **own** External Secrets Operator instance; application workloads run
  only in spokes. `dev` deploys automatically on merge, `uat` and `prod`
  by reviewed PR. On AWS the target is one account per environment.
  *The local lab (Phase 2.7.1), the aws-eks profile, and Terraform
  (Phase 2.7.2) all use `dev`/`uat`/`prod`.*
- **EKS Pod Identity** is the default workload identity mechanism; IRSA
  is an explicit compatibility path.
- **External Secrets Operator + AWS Secrets Manager**, one ESO instance
  per cluster, with a layered isolation model — not a single Kubernetes
  object.
- **Production promotion** requires a reviewed pull request, and that PR
  gate is paired with `AppProject`/RBAC/least-privilege-credential
  controls — a PR alone is treated as necessary, not sufficient.

Full detail, diagrams, risks, and current implementation status live in
the [Technical Architecture Document](docs/architecture/technical-architecture.md).

## Current status

**Phase 1 (documentation foundation), Phase 2.1 (local tooling and
`kind` foundation), Phase 2.2 (Argo CD bootstrap), Phase 2.3 (private
GitOps bootstrap), Phase 2.4 (standard workload contract), Phase 2.5
(repository governance baseline), Phase 2.6.1 (External Secrets
Operator bootstrap), Phase 2.6.2 (External Secrets workload
contract), Phase 2.6.3a (transactional GitOps lifecycle and safe
revision rollback), Phase 2.6.3b (source-secret idempotency and
kubeconfig evidence hardening), Phase 2.7.1 (`dev`/`uat`/`prod`
environments in the local lab), and Phase 2.7.2 (the same environments
in the aws-eks profile and Terraform, offline), and Phase 2.7.3 (hub
and spoke `kind` clusters with Argo CD registration) are implemented** — a single, pinned `lab-lite`
`kind` cluster running a pinned, digest-verified Argo CD control plane,
reconciling this repository's own `gitops/` directory over a read-only
SSH deploy key into `dev`, `uat`, and `prod` namespaces, each
running a real Restricted-PSS-compliant
`Deployment`/`Service`/`ServiceAccount`/`ConfigMap`
(`charts/standard-workload`, a pinned, non-root `podinfo` image) instead
of the earlier smoke `ConfigMap`, plus two namespace-scoped External
Secrets Operator controllers (one per environment), each now backed by
its own namespaced `SecretStore`/`ExternalSecret` pair (Kubernetes-
provider local backend) that reconciles an imperative, out-of-Git
source Secret into a target Secret ESO owns exclusively, mounted into
the workload as a read-only volume — never an environment variable, and
never a `Secret` manifest in Git. No Keycloak
yet — postponed, not rejected (ADR-0008).

**Phase 3.1–3.3.5 (Terraform EKS/network foundation, Pod Identity/Secrets
Manager IaC, dual-provider secret contract, GitOps profile mechanism, and
the EKS identity boundary) exist as code, offline-validated only.** See
"AWS EKS profile" below — none of it is deployed, and no AWS account
exists to deploy it against. `main` currently
relies on process (PR + a passing `validate` check), not GitHub-enforced
branch protection. The repository is now public, so branch protection is
available at no cost; applying it is a separately authorized step
(ADR-0009). An `Accepted` ADR records an approved decision, not
necessarily a fully implemented one. See the TAD's evidence table and
delivery roadmap for what exists versus what is proposed.

### What comes next

| Phase | Scope | Status |
|---|---|---|
| 2.7.1 | `dev`/`uat`/`prod` in the local lab (`staging` → `uat`, `production` → `prod`, `dev` added, three ESO releases) | Implemented |
| 2.7.2 | Same rename in the aws-eks profile and Terraform, `dev` added there too (offline) | Implemented |
| 2.7.3 | `lab-multicluster`: `management` hub + `dev`/`uat` spokes (`prod` opt-in) in `kind`; spoke registration with a namespace-scoped, rotating credential | Implemented |
| 2.7.4 | Cluster-generator `ApplicationSet` and one ESO per spoke; `make mc-up` brings the whole profile up | Implemented |
| 2.8.1 | Workload resilience in the standard chart: PodDisruptionBudget, topology spread, graceful shutdown, NetworkPolicy (`make workload-test-resilience`) | Implemented |
| 2.8.2 | metrics-server per workload cluster and an HPA in `prod` (`make workload-test-autoscaling`) | Implemented |
| 3.4.1 | AWS organization and guardrails (plan-only): five member accounts, service control policies, organization trail, delegated security administration (GuardDuty, Security Hub, Config, Access Analyzer), consolidated budget | Implemented (offline) |
| 3.4.2 | Per-account baseline (plan-only): Config recorders in every allowed region delivering to a central bucket, EBS encryption and IMDSv2 defaults, S3 account public access block, per-account budgets | Implemented (offline) |
| 3.4.3a | Per-environment network and EKS (plan-only): system node group, five managed add-ons at explicit versions (VPC CNI with NetworkPolicy and its own Pod Identity, metrics-server); closes R-14, so the aws overlays turn NetworkPolicy and the prod HPA on | Implemented (offline) |
| 3.4.3b–3.4.4 | Karpenter and ECR; per-spoke ESO identity; hub-to-spoke Argo CD identity on EKS (plan-only) | `PROPOSED` |
| 5.1 | Image CI: build, vulnerability scan, SBOM, signing, push; tag-bump promotion `dev` → `uat` → `prod` | `PROPOSED` |
| 5.2 | Terraform CI: `plan` on every PR, static analysis, `apply` against a local AWS emulator | `PROPOSED` |
| 6.1 | Observability: per-spoke metrics shipped to the hub, dashboards, logs, one SLO with tested burn-rate alerts, Argo CD health alerts | `PROPOSED` |
| 6.2 | Backup and restore drill | `PROPOSED` |
| 6.3 | Multi-language reference application with a data store, replacing `podinfo` | `PROPOSED` |

Full detail and ordering live in the TAD's
[Delivery Roadmap](docs/architecture/technical-architecture.md#delivery-roadmap).

## Local lab

Phase 2.1 provides a pinned, project-local `kind` cluster with zero
dependency on the machine's global `kubectl`/`kind` installation or
kubeconfig:

```bash
make tools-check       # read-only: verify the pinned local toolchain is installed
make tools-install     # download + checksum-verify kind/kubectl into .tools/bin/ (mutates .tools/ only)
make lab-create        # create the pinned lab-lite cluster (no-op if it already matches)
make lab-status        # read-only health/identity report
make lab-test          # read-only shape/identity checks against the existing cluster
make lab-test-lifecycle # mutating: proves create/destroy idempotency (cluster must be absent first)
make lab-destroy       # destroy only the exact project cluster (no-op if absent)
```

All lab commands use `.tools/bin/kind` and `.tools/bin/kubectl` (never
the global binaries) and `.local/kubeconfig` (never `~/.kube/config` or
the shell's current context) — both paths are gitignored. `lab-lite` is
a single physical cluster; `dev`/`uat`/`prod` are namespace-level
simulations at this stage, not real multi-cluster isolation (see the
TAD's "Cluster and Environment Topology"). Phase 2.1 creates only the
cluster itself — no `dev`/`uat`/`prod` namespace, no Argo CD, per
the imperative/declarative boundary in the TAD.

## Local lab: Argo CD bootstrap

Phase 2.2 installs Argo CD into the Phase 2.1 `lab-lite` cluster via a
pinned, checksum-verified Helm CLI and an immutable, digest-pinned chart
release — never `helm repo add`, never a floating tag:

```bash
make argocd-chart-fetch      # download + checksum-verify the pinned argo-cd-10.4.2 chart (only target allowed to fetch it)
make argocd-render           # fully offline render; proves every image is approved and digest-pinned
make argocd-install          # fail-closed idempotent install: absent->install, exact match->no-op, any drift->fail closed
make argocd-status           # read-only release/workload/CRD status report
make argocd-test-runtime-health # read-only health checks against an installed release
make argocd-test-lifecycle   # mutating: proves install/no-op/uninstall/restore idempotency and CRD retention end-to-end
make argocd-port-forward     # foreground port-forward to the Argo CD UI/API at https://localhost:8443
make argocd-uninstall        # uninstall the release; CRDs retained; namespace deleted only if owned and inventory-clean
```

Argo CD's own `dex` and `notifications-controller` are disabled; every
rendered image is digest-pinned; every rendered container has explicit
CPU/memory requests and limits. Phase 2.2 installs only the Argo CD
control plane itself — no root/bootstrap `Application`, `AppProject`, or
`ApplicationSet`, which are declarative, Phase 2.3 concerns (see the
TAD's "Local Lab Argo CD Bootstrap" and "GitOps Control Plane" sections).

## Local lab: private GitOps bootstrap

Phase 2.3 gives Argo CD read-only SSH access to this private repository
and reconciles the `dev`, `uat`, and `prod` environments from
`gitops/` — only the root `Application` and the Argo CD repository
credential `Secret` are ever applied imperatively; everything else
(`AppProject`, `ApplicationSet`, the two generated `Application`
objects, both namespaces, both `ConfigMap`s) is Git-reconciled:

```bash
make gitops-repo-setup       # idempotently provision the deploy key, GitHub deploy key, and Argo CD repository Secret
make gitops-repo-check       # read-only equivalent of the above (no mutation)
make gitops-render           # fully offline render; proves exactly 1 AppProject/1 ApplicationSet/2 generators/0 Secrets/no wildcards
make gitops-bootstrap        # fail-closed idempotent apply of the root Application only (REVISION=<value>, default main)
make gitops-status           # read-only status report
make gitops-test             # read-only runtime health checks
make gitops-test-lifecycle   # mutating: proves bootstrap/no-op/self-heal/isolation/uninstall/no-op (REVISION=<pushed branch>)
make gitops-uninstall        # two-phase transactional uninstall (Phase 2.6.3a): read-only preflight classification first, zero mutation on any unclassifiable object; retains a namespace an active ESO scoped release still targets
make gitops-repo-remove      # remove the repository Secret/deploy key (requires CONFIRM=REMOVE; never run by the lifecycle test)
```

Phase 2.6.3a hardens three GitOps lifecycle operations discovered to be
unsafe while testing Phase 2.6.2 against a cluster that also has ESO
installed (see `.local/evidence/phase-2.6.3-gitops-lifecycle-hardening-plan.md`,
local-only/gitignored like every other phase's planning document, for
the full root-cause analysis):

```bash
make gitops-switch-revision              # safely switch the root Application's targetRevision in place (patch, never delete+recreate); preserves UID/finalizers; requires 3 consecutive stable reads; rolls back automatically on failure (REVISION=<value>)
make gitops-test-revision-switch         # mutating: proves the above end-to-end (REVISION=<pushed branch>)
make gitops-retire-appproject-kind       # drain SecretStore/ExternalSecret from one environment before narrowing the AppProject whitelist - pauses self-heal, deletes while still whitelisted, verifies target-Secret retention, never leaves self-heal silently disabled (ENV=dev|uat|prod ACTION=--drain)
make gitops-resume-appproject-kind       # resume automated sync after the drain + the whitelist-narrowing Git change have both landed (ENV=dev|uat|prod)
make gitops-test-appproject-kind-retirement  # mutating: proves the full 8-step drain/resume sequence end-to-end
```

`gitops-uninstall`'s previous single-phase version deleted the root
Application first and only checked namespace contents afterward -
once ESO's scoped-RBAC `Role`/`RoleBinding` objects exist inside
`uat`/`prod` (Phase 2.6.1), that check always refused to
delete the namespace, but the workloads were already gone by then. The
two-phase version classifies every namespaced object
(`argocd-tracked`/`helm-eso-scoped`/`kubernetes-builtin`/`unknown`,
verified via real tracking-id/Helm-ownership metadata, never a name
guess) **before** touching the root Application, and aborts with zero
mutation if anything is unclassifiable.

The deploy key is repository-scoped and read-only — see
[ADR-0007](docs/adr/0007-private-gitops-bootstrap.md) for the full
comparison against a public repo, an HTTPS PAT, and a GitHub App. Its
private half never enters Git: it lives only at
`.local/gitops/github-deploy-key` (gitignored, mode `0600`) and as the
Argo CD repository Secret in-cluster — no script ever prints it.

## Local lab: standard workload contract

Phase 2.4 replaces the ConfigMap-only smoke example with a real,
reusable Helm chart at `charts/standard-workload/` — `Deployment`,
`Service`, `ServiceAccount`, `ConfigMap` only, Restricted-Pod-Security-
Standards-compliant by default (non-root UID/GID `65532`, dropped
capabilities, read-only root filesystem, `seccompProfile:
RuntimeDefault`), running a digest-pinned, non-root, multi-arch
`podinfo` image. `dev`/`uat`/`prod` differ in replica count,
resources, and a `PODINFO_UI_MESSAGE` value sourced from the chart's
own `ConfigMap` — proven functionally consumed via `GET /api/info`, not
just checksum-decoration. Ingress/HPA/PodDisruptionBudget/NetworkPolicy/
ServiceMonitor remain deliberately unimplemented (ADR-0006's
phased-implementation note) — never dead-configured.

```bash
make check-standard-workload-chart  # offline lint/render/schema/PSS/dry-run validation for both environments (also runs as part of `make validate`)
```

See [ADR-0008](docs/adr/0008-standard-workload-before-sso.md) for why
this phase came before Keycloak/SSO, not instead of it.

## Local lab: hub and spoke clusters (`lab-multicluster`)

Phase 2.7.3 adds a second local profile (ADR-0015): one `kind` cluster
for the `management` hub plus one per spoke. Every lab target accepts
`LAB_CLUSTER=lab-lite|hub|dev|uat|prod` (default `lab-lite`). lab-lite
and lab-multicluster never run at the same time.

Phase 2.7.4 puts the workloads in the spokes: the hub's Argo CD
generates one Application per registered spoke, and each spoke runs its
own ESO. One command does everything, in the only order that works on
fresh clusters, and is a no-op when run again:

```bash
make lab-destroy                              # lab-lite must be down first
make mc-up                                    # hub + dev + uat, Argo CD, registration, ESO, source Secrets, bootstrap
make mc-up SPOKES=dev,uat,prod                # same, with prod
make mc-test-e2e REVISION=<branch>            # mutating end-to-end proof (starts from nothing)
make mc-spoke-deregister SPOKE=dev            # removes dev's Application and workloads first, then its access
make lab-mc-destroy
```

The individual steps, as Phase 2.7.3 introduced them:

```bash
make lab-destroy                              # lab-lite must be down first
make lab-mc-create                            # hub + dev + uat (SPOKES=dev,uat,prod adds prod)
make argocd-install LAB_CLUSTER=hub           # Argo CD on the hub only
make gitops-repo-setup LAB_CLUSTER=hub        # repository Secret on the hub
make mc-spoke-register SPOKE=dev              # namespace-scoped credential, 24h token; re-run rotates it
make mc-spoke-register SPOKE=uat
make lab-mc-status                            # identity, registration (never the token), memory per member
make mc-test-registration REVISION=<branch>   # mutating end-to-end registration proof
make lab-mc-destroy
```

Each spoke's credential can manage only the six AppProject kinds in its
own namespace: no ClusterRole, no Secrets, no `kube-system`. Measured
memory for the hub plus three spokes is about 4.4 GiB with ESO and the
workloads. See the TAD's "Hub-and-Spoke Registration" and "Cluster
Generator and Per-Spoke ESO" sections.

## Repository governance

Phase 2.5 applied the repository governance controls that were available
while this repository was **private on GitHub Free**: Dependabot vulnerability
alerts and automated security updates are enabled; Dependabot version
updates are configured for the one dependency ecosystem this repository
actually has (`.github/dependabot.yml`, `github-actions` only); GitHub
Actions are restricted to GitHub-owned actions with immutable SHA
pinning required platform-side; and the merge button only offers a real
merge commit (squash and rebase merging are disabled).

**`main` is not GitHub-protected yet.** While the repository was
private on GitHub Free, branch protection and rulesets were unavailable.
The repository is now public, and as of 2026-11-10 the GitHub API
reports `main` as available but `Branch not protected`. Until the
ruleset is applied (a repository-settings change that needs its own
explicit authorization), `main` is protected only by process: every
change goes through a pull request, and a passing `validate` run is
required before merge. The exact ruleset design is specified and ready
to apply — see
[ADR-0009](docs/adr/0009-repository-governance-baseline.md).

## Local lab: External Secrets Operator bootstrap

Phase 2.6.1 installs the External Secrets Operator (`v2.10.0`, chart
`2.10.0`) with its 25 CRDs applied once and owned by no Helm release
(`kubectl apply`, never a release — the chart renders them as plain
templates with no retention annotation, so a release that owned them
would delete them on `helm uninstall`), and **two namespace-scoped
controller releases** (three since Phase 2.7.1) — `eso-uat` (watches
only `uat`), `eso-dev` (only `dev`), and `eso-prod` (only `prod`), each with `scopedRBAC:
true` converting every cluster-scoped RBAC rule the controller itself
needs into a `Role`/`RoleBinding` restricted to exactly that one
namespace. The webhook and cert-controller components are cluster-wide
singletons by construction (their object names are fixed, not
release-qualified) and run from `eso-uat` only — proven, not
assumed, by a collision/ownership gate that renders the full
architecture offline before anything is ever applied. CRDs are applied
under a single stable field manager with a `--dry-run=server` preflight
first — a genuine field-ownership conflict stops the install with the
CRD completely untouched; `--force-conflicts` is never used. Because
`eso-dev` and `eso-prod` have no webhook/cert-controller of their own,
they depend on `eso-uat`'s — `make eso-uninstall ENV=uat` is refused
outright while either of them still exists, and `make eso-status`
fails if either exists but that shared webhook/cert-controller
is unhealthy:

```bash
make eso-chart-fetch          # download + checksum-verify the pinned external-secrets-2.10.0 chart (only target allowed to fetch it)
make eso-render                # fully offline render + collision/ownership proof (25 CRDs, no cross-release collision, webhook/cert-controller singleton, zero structural wildcard RBAC, digest-only images)
make check-eso-chart           # helm lint + the same proof (standalone - requires the network-fetched chart, so not part of `make validate`)
make eso-install                # fail-closed idempotent install: CRD preflight (no force) + both scoped releases
make eso-status                 # read-only CRD/release/Deployment health report, including the shared-singleton dependency check
make eso-test-runtime-health   # read-only health checks against an installed bootstrap
make eso-test-lifecycle        # mutating: proves install/no-op/singleton guards/CRD-conflict fail-closed/uninstall(CRDs retained)/no-op/restore end-to-end
make eso-uninstall              # uninstall all three scoped releases (prod, dev, then uat; ENV=dev|uat|prod for one at a time); never touches the CRDs; refuses uat while dev or prod exists
```

Phase 2.8.2: `prod` runs an HPA, which needs metrics-server on the same
cluster before the bootstrap (otherwise `prod` reports Degraded). `make
mc-up` installs it on every spoke; on lab-lite:

```bash
make metrics-server-chart-fetch   # download + checksum-verify the pinned chart (3.14.0)
make metrics-server-install       # fail-closed idempotent install (LAB_CLUSTER=dev|uat|prod for a spoke; never the hub)
make metrics-server-status        # release, APIService and node metrics
make workload-hpa-handover NS=prod DEPLOYMENT=platform-smoke-prod-standard-workload   # once, before Git puts an existing Deployment under an HPA
make workload-test-autoscaling REVISION=<branch> PRE_REVISION=<branch without the HPA>  # mutating HPA proof
```

Phase 2.6.2 adds the per-environment `SecretStore`/`ExternalSecret`
reconciliation contract on top of that bootstrap. The `kubernetes`-
provider `SecretStore` in each of `dev`/`uat`/`prod` reads from a
dedicated `eso-source-<env>` namespace that
is never touched by Argo CD or this chart — its Secret is created and
rotated exclusively by `lab/eso/provision-source-secret.sh`, an
imperative, out-of-Git script that reads the value only from stdin or
an echo-disabled prompt, never a CLI argument, and never prints it.
Each `ExternalSecret` reconciles that source into a target Secret it
owns exclusively (`creationPolicy: Owner`, `deletionPolicy: Retain`),
which `charts/standard-workload` mounts as a read-only volume
(`externalSecret.enabled`) — never `env`/`envFrom`. `dev`, `uat`, and
`prod` are pairwise isolated: distinct `SecretStore`s, distinct
source namespaces/Secrets, distinct auth `ServiceAccount`s, and no
`SecretStore` can resolve another environment's Secret. The `AppProject` grants
only the two new namespaced kinds (`SecretStore`, `ExternalSecret`) —
never `Secret`; Argo CD never manages a Secret in this design.

Phase 2.6.3b makes the script's default invocation genuinely
idempotent (`ensure`): if the source Secret already exists, it is a
true no-op — never read, never re-applied, and the piped/prompted
value is never even consumed — preserving the Secret's UID,
resourceVersion, content hash, and its Role/RoleBinding untouched.
Rotating an existing value requires the explicit `--rotate` flag.

```bash
make eso-provision-source-secret ENV=uat                    # ensure: create if absent, true no-op if already present (value never read on the no-op path)
make eso-provision-source-secret ENV=prod                 # same, prod (and ENV=dev)
make eso-provision-source-secret ENV=uat ACTION=--rotate    # rotate an EXISTING uat value only (fails if absent); preserves UID, changes resourceVersion/hash, never another environment
make eso-provision-source-secret ENV=uat ACTION=--delete    # idempotent teardown of that environment's source namespace
make eso-test-secret-lifecycle    # mutating: provision -> every SecretStore/ExternalSecret Ready -> target Secrets owned by ESO -> read-only mount hash-verified per environment -> uat/prod isolation -> controlled rotation + propagation (production unaffected) -> target-Secret delete/ESO-recreate -> no-op bootstrap -> ESO uninstall with target-Secret retention -> restore
make eso-test-provision-source-secret-idempotency  # mutating: proves ensure/--rotate/--delete semantics and the global kubeconfig fingerprint helper's isolation, restoring the pre-test value/state on exit
```

See [ADR-0010](docs/adr/0010-external-secrets-operator-contract.md) for
the full rationale, including why the chart's own default (both
releases running the webhook) was rejected after the collision gate
proved it would collide, not merely duplicate, and why the source
Secret lives outside both Git and Helm ownership.

## Main components

| Component | Role |
|---|---|
| Terraform | AWS infrastructure (VPC, EKS, IAM, KMS, Pod Identity associations) |
| Argo CD + `ApplicationSet` | GitOps reconciliation across environments |
| Standard workload chart | The one Helm chart every workload uses |
| EKS Pod Identity / IRSA | Workload-to-AWS identity (default / compatibility) |
| External Secrets Operator + AWS Secrets Manager | Secrets, never in Git — one ESO instance per cluster |
| IAM Identity Center + Keycloak | Human access to AWS/EKS, and to Argo CD in the local lab |
| `kind` | Local lab with no AWS service charges, for GitOps and identity-contract shape testing |

## Architecture Decision Records

All fifteen are `Accepted` — an approved decision, not necessarily a
fully implemented one. 0001–0003 and 0006–0010 have runtime-tested code
behind them; 0004 and 0011–0014 have offline-validated code only; 0005
and 0015 are design decisions not yet implemented.

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-platform-scope-and-boundaries.md) | Platform scope and repository boundaries |
| [0002](docs/adr/0002-environment-topology.md) | Environment topology |
| [0003](docs/adr/0003-gitops-control-plane-and-promotion.md) | GitOps control plane and promotion |
| [0004](docs/adr/0004-workload-identity-and-secrets.md) | Workload identity and secrets |
| [0005](docs/adr/0005-sso-bootstrap-and-cluster-access.md) | SSO, bootstrap, and cluster access |
| [0006](docs/adr/0006-standard-workload-contract.md) | Standard workload contract |
| [0007](docs/adr/0007-private-gitops-bootstrap.md) | Private repository GitOps bootstrap |
| [0008](docs/adr/0008-standard-workload-before-sso.md) | Standard workload contract before SSO |
| [0009](docs/adr/0009-repository-governance-baseline.md) | Repository governance baseline |
| [0010](docs/adr/0010-external-secrets-operator-contract.md) | External Secrets Operator contract |
| [0011](docs/adr/0011-terraform-foundation.md) | Terraform foundation |
| [0012](docs/adr/0012-network-eks-iac-foundation.md) | Network and EKS IaC foundation |
| [0013](docs/adr/0013-pod-identity-secrets-manager-iac.md) | EKS Pod Identity and AWS Secrets Manager IaC |
| [0014](docs/adr/0014-eks-application-identity-boundary.md) | EKS application generation and identity boundary |
| [0015](docs/adr/0015-hub-and-spoke-environment-model.md) | Hub-and-spoke environment model (`management` + `dev`/`uat`/`prod`) |

## Working locally

```bash
make help      # list all available targets
make validate  # run every documentation validation check
```

## AWS EKS profile (`DESIGNED` / `STATICALLY VALIDATED` / `NOT DEPLOYED` / `NOT VALIDATED AGAINST AWS` — `ACTUAL COST: USD 0`)

**Runs today, against the `kind` lab:** everything in "Current status"
above — `make lab-create`, `make argocd-install`, `make gitops-bootstrap`
(default `PROFILE=local-kind`), `make eso-install`, and every `*-test*`
target. None of these touch AWS or require an AWS account.

**Designed only, not deployed, no AWS account exists to deploy it against:**
`terraform/envs/{network,eks,identity}` (VPC, EKS, Pod Identity Agent,
per-environment IAM/KMS/Secrets Manager metadata, Pod Identity
Associations); `charts/standard-workload`'s `aws` provider branch and its
`values-{dev,uat,prod}-aws.yaml` overlays;
`gitops/bootstrap`'s `profile: aws-eks` (explicit-only, never the
default); `scripts/lab/_lib.sh`'s `check_eks_cluster_identity()`. See
ADR-0013, ADR-0014, and `docs/runbooks/eks-bootstrap-order.md` (a
documented, not executed, future sequence).

**Statically validated today, entirely offline:** `terraform fmt/init
-backend=false/validate/test` (with `mock_provider "aws"`) for every
Terraform root; `helm lint`/`helm template` for both chart providers and
both GitOps profiles; `tests/lab/test-eks-identity-offline.sh` (a fake
`kubectl` and a fake `aws` that fails immediately if invoked - proving
the EKS identity check never shells out to the real AWS CLI). Run any of
these with:

```sh
make validate
make terraform-validate-offline
make gitops-render
make lab-test-eks-identity-offline
```

None of the above contacts AWS, mutates the `kind` cluster, or requires
any credential.

**Currently prohibited, project-wide, until an AWS account and budget
exist:** `terraform plan`/`apply`/`destroy`/`import`/`refresh` against a
real backend, any `aws` CLI invocation, and any mutation of
`lab/gitops/bootstrap.sh`'s `aws-eks` branch past its own identity
preflight (it deliberately stops before any `kubectl apply`, `helm
install`, or equivalent - see ADR-0014).

## Safety

**No `terraform apply`, no mutating `kubectl`, no AWS resource, and no
change to any external system (repository settings, remote branches,
secrets) happens without a fresh, explicit, scoped authorization first.**
See `AGENTS.md` for the full safety-gate rules that apply to anyone —
human or AI agent — working in this repository.

## Contributing

1. Open a pull request for every change — no direct commits once branch
   protection is configured.
2. Run `make validate` before proposing any change.
3. If a change affects architecture, update the TAD and/or the relevant
   ADR in the same PR — documentation drift is treated as a defect.
4. Keep changes scoped to the current delivery phase (see the TAD's
   roadmap); a PR reaching into a later phase should be split.
5. New ADRs start `Proposed`; moving one to `Accepted` requires an
   explicit review, not just a passing CI run.
6. Never introduce a secret value, and never reference any local-only,
   non-shared material by name — see `AGENTS.md` and `SECURITY.md`.

See `AGENTS.md` for the complete operating rules.

## License

[Apache License 2.0](LICENSE).
