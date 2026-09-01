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

**Phase 1 (documentation foundation) is complete; Phase 2 (local lab)
has not started.** This repository currently contains documentation and
an accepted architecture baseline only — no Terraform, no Helm charts,
no Kubernetes manifests, no `kind` cluster, no Argo CD or Keycloak
installation. An `Accepted` ADR records an approved decision, not an
implemented one. See the TAD's evidence table and delivery roadmap for
what exists versus what is proposed.

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

All six are `Accepted` — an approved decision, not an implemented one.

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-platform-scope-and-boundaries.md) | Platform scope and repository boundaries |
| [0002](docs/adr/0002-environment-topology.md) | Environment topology |
| [0003](docs/adr/0003-gitops-control-plane-and-promotion.md) | GitOps control plane and promotion |
| [0004](docs/adr/0004-workload-identity-and-secrets.md) | Workload identity and secrets |
| [0005](docs/adr/0005-sso-bootstrap-and-cluster-access.md) | SSO, bootstrap, and cluster access |
| [0006](docs/adr/0006-standard-workload-contract.md) | Standard workload contract |

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
