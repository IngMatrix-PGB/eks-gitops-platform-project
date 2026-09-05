# eks-gitops-platform-project

A greenfield, portfolio-quality GitOps platform for AWS EKS, built from
scratch in small, reviewable phases. It demonstrates reproducible AWS/EKS
infrastructure, workload identity without static credentials, secrets
that never enter Git, Argo CD-driven environment reconciliation, and
production promotion gated by a reviewed pull request plus runtime trust
boundaries.

## Target architecture, in brief

- **Terraform** provisions AWS infrastructure; **Argo CD**, running in
  `management`, pulls desired state from Git and reconciles it toward
  `staging`/`prod` after bootstrap.
- **`management` / `staging` / `prod`** environments — `management` is
  the control plane only (Argo CD, Keycloak for the local lab); each of
  the three clusters runs its **own** External Secrets Operator instance
  for the secrets it needs; application workloads run only in
  `staging`/`prod`.
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
contract), and Phase 2.6.3a (transactional GitOps lifecycle and safe
revision rollback) are implemented** — a single, pinned `lab-lite`
`kind` cluster running a pinned, digest-verified Argo CD control plane,
reconciling this repository's own `gitops/` directory over a read-only
SSH deploy key into a `staging` and a `production` namespace, each
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
yet — postponed, not rejected (ADR-0008). No Terraform. `main` currently
relies on process (PR + a passing `validate` check), not GitHub-enforced
branch protection — this repository is private on GitHub Free, which
does not offer branch protection or rulesets for a private repository
(ADR-0009). An `Accepted` ADR records an approved decision, not
necessarily a fully implemented one. See the TAD's evidence table and
delivery roadmap for what exists versus what is proposed.

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
a single physical cluster; `staging`/`production` are namespace-level
simulations at this stage, not real multi-cluster isolation (see the
TAD's "Cluster and Environment Topology"). Phase 2.1 creates only the
cluster itself — no `staging`/`production` namespace, no Argo CD, per
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
and reconciles a `staging` and a `production` environment from
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
installed (see
[the hardening plan](.local/evidence/phase-2.6.3-gitops-lifecycle-hardening-plan.md)
for the full root-cause analysis):

```bash
make gitops-switch-revision              # safely switch the root Application's targetRevision in place (patch, never delete+recreate); preserves UID/finalizers; requires 3 consecutive stable reads; rolls back automatically on failure (REVISION=<value>)
make gitops-test-revision-switch         # mutating: proves the above end-to-end (REVISION=<pushed branch>)
make gitops-retire-appproject-kind       # drain SecretStore/ExternalSecret from one environment before narrowing the AppProject whitelist - pauses self-heal, deletes while still whitelisted, verifies target-Secret retention, never leaves self-heal silently disabled (ENV=staging|production ACTION=--drain)
make gitops-resume-appproject-kind       # resume automated sync after the drain + the whitelist-narrowing Git change have both landed (ENV=staging|production)
make gitops-test-appproject-kind-retirement  # mutating: proves the full 8-step drain/resume sequence end-to-end
```

`gitops-uninstall`'s previous single-phase version deleted the root
Application first and only checked namespace contents afterward -
once ESO's scoped-RBAC `Role`/`RoleBinding` objects exist inside
`staging`/`production` (Phase 2.6.1), that check always refused to
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
`podinfo` image. `staging`/`production` differ in replica count,
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

## Repository governance

Phase 2.5 applies the repository governance controls actually available
on a **private repository on GitHub Free**: Dependabot vulnerability
alerts and automated security updates are enabled; Dependabot version
updates are configured for the one dependency ecosystem this repository
actually has (`.github/dependabot.yml`, `github-actions` only); GitHub
Actions are restricted to GitHub-owned actions with immutable SHA
pinning required platform-side; and the merge button only offers a real
merge commit (squash and rebase merging are disabled).

**`main` is not GitHub-protected.** Classic branch protection and
repository rulesets both require GitHub Pro (or a public repository) for
a private repository — confirmed directly against this repository's own
API responses, not assumed from documentation. The owner chose to keep
the repository private and stay on GitHub Free rather than pay for or
give up privacy to unlock that feature. Until that changes, `main` is
protected only by process: every change goes through a pull request,
and a passing `validate` run is required before merge, by maintainer
discipline rather than server-side enforcement. The exact ruleset design
that would close this gap is fully specified and ready to apply,
unchanged, the moment the plan or visibility decision changes — see
[ADR-0009](docs/adr/0009-repository-governance-baseline.md).

## Local lab: External Secrets Operator bootstrap

Phase 2.6.1 installs the External Secrets Operator (`v2.10.0`, chart
`2.10.0`) with its 25 CRDs applied once and owned by no Helm release
(`kubectl apply`, never a release — the chart renders them as plain
templates with no retention annotation, so a release that owned them
would delete them on `helm uninstall`), and **two namespace-scoped
controller releases** — `eso-staging` (watches only `staging`) and
`eso-production` (watches only `production`), each with `scopedRBAC:
true` converting every cluster-scoped RBAC rule the controller itself
needs into a `Role`/`RoleBinding` restricted to exactly that one
namespace. The webhook and cert-controller components are cluster-wide
singletons by construction (their object names are fixed, not
release-qualified) and run from `eso-staging` only — proven, not
assumed, by a collision/ownership gate that renders the full
architecture offline before anything is ever applied. CRDs are applied
under a single stable field manager with a `--dry-run=server` preflight
first — a genuine field-ownership conflict stops the install with the
CRD completely untouched; `--force-conflicts` is never used. Because
`eso-production` has no webhook/cert-controller of its own, it depends
on `eso-staging`'s — `make eso-uninstall ENV=staging` is refused
outright while `eso-production` still exists, and `make eso-status`
fails if `eso-production` exists but that shared webhook/cert-controller
is unhealthy:

```bash
make eso-chart-fetch          # download + checksum-verify the pinned external-secrets-2.10.0 chart (only target allowed to fetch it)
make eso-render                # fully offline render + collision/ownership proof (25 CRDs, no cross-release collision, webhook/cert-controller singleton, zero structural wildcard RBAC, digest-only images)
make check-eso-chart           # helm lint + the same proof (standalone - requires the network-fetched chart, so not part of `make validate`)
make eso-install                # fail-closed idempotent install: CRD preflight (no force) + both scoped releases
make eso-status                 # read-only CRD/release/Deployment health report, including the shared-singleton dependency check
make eso-test-runtime-health   # read-only health checks against an installed bootstrap
make eso-test-lifecycle        # mutating: proves install/no-op/singleton guards/CRD-conflict fail-closed/uninstall(CRDs retained)/no-op/restore end-to-end
make eso-uninstall              # uninstall both scoped releases (production then staging; ENV=staging|production for one at a time); never touches the CRDs; refuses staging while production exists
```

Phase 2.6.2 adds the per-environment `SecretStore`/`ExternalSecret`
reconciliation contract on top of that bootstrap. The `kubernetes`-
provider `SecretStore` in each of `staging`/`production` reads from a
dedicated `eso-source-staging`/`eso-source-production` namespace that
is never touched by Argo CD or this chart — its Secret is created and
rotated exclusively by `lab/eso/provision-source-secret.sh`, an
imperative, out-of-Git script that reads the value only from stdin or
an echo-disabled prompt, never a CLI argument, and never prints it.
Each `ExternalSecret` reconciles that source into a target Secret it
owns exclusively (`creationPolicy: Owner`, `deletionPolicy: Retain`),
which `charts/standard-workload` mounts as a read-only volume
(`externalSecret.enabled`) — never `env`/`envFrom`. `staging` and
`production` are fully isolated: distinct `SecretStore`s, distinct
source namespaces/Secrets, distinct auth `ServiceAccount`s, and neither
`SecretStore` can resolve the other's Secret. The `AppProject` grants
only the two new namespaced kinds (`SecretStore`, `ExternalSecret`) —
never `Secret`; Argo CD never manages a Secret in this design.

```bash
make eso-provision-source-secret ENV=staging     # create/rotate the staging source Secret (value from stdin/prompt, never argv)
make eso-provision-source-secret ENV=production  # same, production
make eso-provision-source-secret ENV=staging ACTION=--delete  # idempotent teardown of that environment's source namespace
make eso-test-secret-lifecycle    # mutating: provision -> both SecretStores/ExternalSecrets Ready -> target Secrets owned by ESO -> read-only mount hash-verified per environment -> staging/production isolation -> controlled rotation + propagation (production unaffected) -> target-Secret delete/ESO-recreate -> no-op bootstrap -> ESO uninstall with target-Secret retention -> restore
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

All ten are `Accepted` — an approved decision, not necessarily a fully
implemented one (0001–0003, 0006, 0007, 0008, 0009, and 0010 have code behind them today).

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

## Working locally

```bash
make help      # list all available targets
make validate  # run every documentation validation check
```

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
