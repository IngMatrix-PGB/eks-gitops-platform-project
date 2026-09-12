# Runbook: EKS Bootstrap Order

**`DESIGNED` / `NOT DEPLOYED` / `NOT VALIDATED AGAINST AWS` — `ACTUAL COST: USD 0`.**

This runbook documents the future order of operations to bring the
`aws-eks` GitOps profile from "identity preflight only"
([ADR-0014](../adr/0014-eks-application-identity-boundary.md)) to an
actual, applied root Application. **No step in this document has been
executed.** It exists so a future, separately authorized operation has a
single source of order-of-operations truth — it is not a script, and
running it requires an AWS account and budget that do not exist today.

## Preconditions

- An AWS account exists, with a budget explicitly authorized for EKS,
  NAT, and associated compute/networking cost.
- `terraform/envs/{network,eks,identity}` have been reviewed and their
  variables (see table below) set for the target account/region — none
  of them ship with an operative default account ID, ARN, endpoint, or
  region baked into Git.
- The operator has out-of-band AWS credentials sufficient to run
  `terraform apply` (this runbook does not grant or provision them).
- A separate, explicit authorization exists for the specific
  `terraform apply` runs below — this document is not that
  authorization.

## Human inputs required (never defaulted in Git)

| Input | Consumed by | Notes |
|---|---|---|
| AWS account / credentials | Terraform, out-of-band | Never stored in this repo |
| `aws_region` | `terraform/envs/{network,eks,identity}` | e.g. `us-east-1` — no default is treated as operative |
| `admin_principal_arn`, `breakglass_principal_arn` | `terraform/envs/eks` | Real IAM principal ARNs, provided at apply time |
| `cluster_name` | `terraform/envs/eks`, `terraform/envs/identity` | Must match between both roots |
| `vpc_id`, `private_subnet_ids` | `terraform/envs/eks` | Terraform outputs from `terraform/envs/network`, wired explicitly, not assumed |
| `EKS_KUBECONFIG` | `lab/gitops/bootstrap.sh` (`aws-eks` profile) | Path to an isolated kubeconfig — never `$HOME/.kube/config`, never `.local/kubeconfig` |
| `EKS_CONTEXT`, `EKS_CLUSTER_NAME`, `EKS_REGION`, `EKS_ENDPOINT` | `scripts/lab/_lib.sh`'s `check_eks_cluster_identity()` | Must all agree with each other and with the real cluster |
| `REVISION` | `lab/gitops/bootstrap.sh` | Git revision to reconcile from — defaults to `main` only if unset, same as `local-kind` |

## Future order (documented, not executed)

1. **Terraform: network.** Run `terraform apply` in `terraform/envs/network`
   with the target account's real `aws_region`/`vpc_cidr`/
   `availability_zones`. Produces `vpc_id`, `private_subnet_ids`,
   `public_subnet_ids`.
2. **Terraform: EKS.** Run `terraform apply` in `terraform/envs/eks`,
   wiring `vpc_id`/`private_subnet_ids` from step 1 and the real
   `admin_principal_arn`/`breakglass_principal_arn`/`cluster_name`.
   Produces `cluster_name`, `cluster_endpoint` outputs and installs the
   Pod Identity Agent addon.
3. **Terraform: identity.** Run `terraform apply` in
   `terraform/envs/identity`, wiring the same `cluster_name` and the
   real `staging_namespace`/`production_namespace`/
   `staging_service_account`/`production_service_account`. Produces
   per-environment Pod Identity Associations, KMS keys, and Secrets
   Manager secrets (empty payload — no value is written by Terraform;
   see the migration runbook below for how a payload is populated).
4. **Isolated kubeconfig creation.** Generate a project-local kubeconfig
   file at a path distinct from both `$HOME/.kube/config` and
   `.local/kubeconfig` (e.g. `.local/kubeconfig-eks`, gitignored),
   pointing at the `cluster_endpoint` from step 2. This is the only step
   in this runbook that would ever touch an AWS-issued credential —
   still no `aws eks update-kubeconfig` call is authorized here; the
   file is expected to be produced by whatever out-of-band tooling the
   operator's own AWS access already requires.
5. **Identity validation.** Run
   `PROFILE=aws-eks EKS_KUBECONFIG=... EKS_CONTEXT=... EKS_CLUSTER_NAME=... EKS_REGION=... EKS_ENDPOINT=... REVISION=... sh lab/gitops/bootstrap.sh`.
   This executes `check_eks_cluster_identity()` and prints the non-secret
   fingerprint — **it stops here today**; the steps below are the
   documented continuation for a future, separately authorized phase
   that extends `lab/gitops/bootstrap.sh`'s `aws-eks)` branch past its
   current stopping point.
6. **Argo CD installation** against the isolated kubeconfig from step 4
   (mirroring `lab/argocd/install.sh`'s kind-cluster flow, but never
   reusing `pkubectl`/`phelm`, which are hardcoded to
   `$PROJECT_KUBECONFIG` — see ADR-0014's Consequences section).
7. **Read-only Git credential.** Provision a deploy key/token scoped to
   read-only access on this repository for the new cluster's Argo CD —
   never the same credential used by the `local-kind` lab.
8. **Root Application with the `aws-eks` profile.** Apply a root
   Application manifest (not yet created — this phase deliberately does
   not create `root-application-aws-eks.yaml`) whose `gitops/bootstrap`
   chart values set `profile: aws-eks`, reconciling the
   `staging-aws`/`production-aws` environment list from
   `gitops/bootstrap/values.yaml`.
9. **ESO installation** against the same isolated kubeconfig, then
   confirmation that `SecretStore`/`ExternalSecret` resources reconcile
   using Pod Identity (no `auth` block — see ADR-0014).
10. **Validation.** Confirm the generated Applications
    (`staging-aws`, `production-aws`) are `Synced`/`Healthy`, and that
    each environment's `ExternalSecret` resolves from the Secrets
    Manager secret produced in step 3.
11. **Abort conditions.** Any of the following aborts the entire
    sequence and requires operator investigation before continuing:
    identity preflight fails (any `EKS_IDENTITY_CASE` other than
    `match`); the isolated kubeconfig resolves to the same path as
    `$HOME/.kube/config` or `.local/kubeconfig`; the read-only Git
    credential cannot authenticate; a generated Application reaches
    `Degraded` health; any step requires a mutating AWS CLI call this
    runbook did not explicitly authorize.

## What this runbook does not authorize

`terraform plan`/`apply`/`destroy`/`import`/`refresh` against a real
backend, any `aws` CLI invocation, and any extension of
`lab/gitops/bootstrap.sh`'s `aws-eks)` branch past its identity
preflight — all remain out of scope for Phase 3 and require a separate,
explicit authorization referencing this runbook by name.
