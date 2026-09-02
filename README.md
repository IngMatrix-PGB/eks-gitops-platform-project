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
`kind` foundation), Phase 2.2 (Argo CD bootstrap), and Phase 2.3
(private GitOps bootstrap) are implemented** — a single, pinned
`lab-lite` `kind` cluster running a pinned, digest-verified Argo CD
control plane, reconciling this repository's own `gitops/` directory
over a read-only SSH deploy key into a `staging` and a `production`
namespace, each holding one GitOps-managed `ConfigMap`. No application
workload beyond that smoke `ConfigMap` exists yet, and no Keycloak. No
Terraform. An `Accepted` ADR records an approved decision, not
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
make gitops-uninstall        # delete the root Application (foreground cascade) and owned namespaces only
make gitops-repo-remove      # remove the repository Secret/deploy key (requires CONFIRM=REMOVE; never run by the lifecycle test)
```

The deploy key is repository-scoped and read-only — see
[ADR-0007](docs/adr/0007-private-gitops-bootstrap.md) for the full
comparison against a public repo, an HTTPS PAT, and a GitHub App. Its
private half never enters Git: it lives only at
`.local/gitops/github-deploy-key` (gitignored, mode `0600`) and as the
Argo CD repository Secret in-cluster — no script ever prints it.

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

All seven are `Accepted` — an approved decision, not necessarily a fully
implemented one (0001–0003 and 0007 have code behind them today).

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-platform-scope-and-boundaries.md) | Platform scope and repository boundaries |
| [0002](docs/adr/0002-environment-topology.md) | Environment topology |
| [0003](docs/adr/0003-gitops-control-plane-and-promotion.md) | GitOps control plane and promotion |
| [0004](docs/adr/0004-workload-identity-and-secrets.md) | Workload identity and secrets |
| [0005](docs/adr/0005-sso-bootstrap-and-cluster-access.md) | SSO, bootstrap, and cluster access |
| [0006](docs/adr/0006-standard-workload-contract.md) | Standard workload contract |
| [0007](docs/adr/0007-private-gitops-bootstrap.md) | Private repository GitOps bootstrap |

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
