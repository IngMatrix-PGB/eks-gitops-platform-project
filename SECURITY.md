# Security Policy

## Reporting a concern

This is a personal portfolio/reference project. If you find a security
issue in the design or in any code committed here, please open an issue
in this repository describing the concern. Do not include real
credentials, tokens, or account identifiers in the report — describe the
class of issue and, if needed, share sensitive details privately with the
maintainer.

## Baseline rules enforced in this repository

- **No secret value** (API key, password, private key, access token,
  connection string with embedded credentials) is ever committed —
  checked locally by `scripts/validate/check-secrets.sh` and
  `make validate`, within that script's documented pattern coverage.
- **No mutation to AWS, a non-disposable Kubernetes cluster, or any
  remote/external system** (repository settings, branch protection,
  secrets) happens without a fresh, explicit authorization for that
  specific action — see `AGENTS.md` for the full safety-gate rules.
- **Least privilege is the target model** throughout: workload identity
  (EKS Pod Identity by default, IRSA as explicit compatibility), the
  External Secrets Operator controller's own identity, and Argo CD's
  cluster credentials are all designed to be scoped as narrowly as
  possible — never a broad, convenient credential used by default.
- Secret values are managed exclusively through External Secrets
  Operator + AWS Secrets Manager once implemented; they are never stored
  in Git, Helm values, or CI variables in plaintext.

## Threat model

The full threat model — including the explicit statement that a
compromised Argo CD controller or an over-privileged credential can
bypass branch protection, and the current status of every mitigation —
lives in
[`docs/architecture/technical-architecture.md`](docs/architecture/technical-architecture.md),
in the "Security and Trust Boundaries" and "Risks and Open Questions"
sections. It is updated as the project moves through its delivery
phases, not written once and left stale.
