# ADR-0024: First AWS deployment as a single-account sandbox session

**Status:** Accepted
**Date:** 2026-11-24

## Context

Roadmap item 6.4 is the first real AWS deployment: the hub plus one
spoke, created and destroyed in one authorized session, with the cost
measured. It is the only way to meet Definition-of-Done criterion 4
(EKS Pod Identity proven on a real cluster). Measured on main at
`35bf537`, before this decision:

- **Accounts.** The Terraform design is one account per environment
  (ADR-0016). `terraform/envs/eks` required `spoke_account_ids` to hold
  exactly dev, uat and prod, so a hub with one spoke in its own account
  failed validation. The IAM role names were already distinct per
  environment, so they fit in one account.
- **Running Terraform.** No root has a backend. `check-terraform-offline`
  allowed `terraform plan`/`apply` only in `scripts/terraform/
  emulator.sh`, which runs against a local emulator and never AWS.
- **Budget.** The only budget was in `terraform/envs/account-baseline`.
  That root also turns on Config, EBS default encryption, IMDS defaults
  and the account-wide S3 public access block, which outlive a session.
- **GitOps.** `lab/gitops/bootstrap.sh` stopped after the EKS identity
  preflight, and there was no root Application for `aws-eks`.
- **Workloads.** Spoke nodes are tainted `CriticalAddonsOnly` so that
  workloads land on Karpenter nodes. Terraform creates Karpenter's IAM
  role and queue, but nothing in the repository installs the Karpenter
  controller.
- **The machine.** On the maintainer's machine, the default AWS
  profile belongs to an unrelated account, so the session must never
  use the default credentials.

## Decision

- **Scope of the session.** One personal sandbox account and one region
  (`us-east-1`), with six Terraform stacks:
  - `budget`;
  - `network-platform`, `eks-platform`: the hub;
  - `network-dev`, `eks-dev`, `identity-dev`: the dev spoke.

  The session deploys smoke only. It does not deploy:
  - notes and postgres, which still need a data-store decision;
  - observability, Velero, or the uat and prod spokes;
  - the organization, SCP and security stacks, which need more than one
    account.
- **Single-account mode.** `spoke_account_ids` takes any non-empty
  subset of dev, uat and prod. Any other key is still refused, and each
  ID must still be 12 digits. The hub may assume only the roles of the
  spokes it lists. The dev spoke's API endpoint admits only the
  operator's /32 and the hub's NAT IP, which comes from a new
  `nat_public_ips` output of `terraform/envs/network`.
- **No Karpenter controller in the session.** `terraform/envs/eks` gains
  `system_nodes_dedicated`:
  - default `true`: the taint stays and nothing changes;
  - the sandbox sets `false`, so ESO and smoke share the spoke's system
    nodes.

  Karpenter's IAM stays in the plan, as before. Installing its
  controller is later work.
- **One guarded runner for real AWS.** `scripts/terraform/aws-session.sh`
  is the second, and last, script allowed to run plan, apply and
  destroy. It has these guards:
  - it refuses to run in CI;
  - `AWS_PROFILE` must be set, and `default` is refused;
  - `aws` and `terraform` run under `env -i`, with only that profile;
  - the account STS reports must be in `.local/eks-sandbox/allowed-accounts`;
  - the generated provider pins `allowed_account_ids` to that account
    and tags every resource with the project and the session;
  - stacks are applied in order, one at a time, and only from a saved
    plan whose inputs have not changed;
  - apply and destroy need `CONFIRM=yes`;
  - destroy goes last stack first;
  - `sweep` fails while anything billable is left.

  Check 9f of `check-terraform-offline` fails if any guard is removed or
  if a workflow calls the script.
- **Local state, no backend.** Each stack runs in a copy under
  `.local/eks-sandbox/work/<stack>/`, as the emulator script does: `init
  -backend=false`, and the state stays in Terraform's local default. The
  S3 bucket from `terraform/bootstrap` is not used: one operator, a
  session of a few hours, and one stack fewer to create and empty.
- **A budget first, kept afterwards.** The new root
  `terraform/envs/sandbox-budget` holds only a monthly budget: USD 20,
  with alerts at 50, 80 and 100 % actual and 100 % forecast.
  - It is the first stack.
  - The sweep allows it to stay, since a budget is free and keeps
    alerting on the session's trailing costs.
- **GitOps on the EKS hub.**
  - `gitops/root-application-aws-eks.yaml` sets `profile=aws-eks` and
    reads the repository through its public HTTPS URL, so no Git
    credential is copied to AWS.
  - `bootstrap.sh` applies it only with `EKS_SESSION_APPLY=1`, using the
    same absent / no-op / drift contract as the local profiles.
  - `lab/eks/session-hub.sh` installs the rest from the pinned charts
    already in the repository: on the spoke, the namespace, Argo CD's
    access and ESO; on the hub, Argo CD, the spoke's cluster Secret
    (`awsAuthConfig`, no token) and the root Application.
  - `lab/eks/session-verify.sh` records the evidence.

## Alternatives Considered

- **One account per environment, as designed.** Rejected for the first
  session: it needs an Organization, several accounts and the guardrail
  stacks. Single-account mode is a subset of that design, so the
  multi-account path stays open.
- **The S3 state bucket.** Rejected for now: it is one more stack to
  create and empty, with no second operator to share state with. It
  stays the answer for a long-lived deployment.
- **Reusing `account-baseline` for the budget.** Rejected: its other
  resources change the account beyond the session and would survive the
  destroy.
- **Installing Karpenter in the session.** Rejected for now. It needs
  another pinned chart, a NodePool and an EC2NodeClass, and adds
  instances that live outside Terraform state. None of that is needed to
  prove Pod Identity or the hub-to-spoke registration.
- **Copying the deploy key to the EKS hub.** Rejected: the repository is
  public, so HTTPS needs no credential at all.

## Consequences

- 6.4b becomes one session of commands that already exist and are
  tested. The runbook
  [eks-sandbox-session](../runbooks/eks-sandbox-session.md) lists them.
- The offline contract now has two exceptions instead of one, each
  checked marker by marker. A third would need its own ADR.
- Everything above is offline-tested only, until 6.4b runs:
  `tests/eks/test-aws-session-guards.sh` (fake `aws` and `terraform`),
  the new `terraform test` cases, and the emulator coverage row for
  `sandbox-budget`.
- KMS keys and Secrets Manager secrets cannot be deleted at once, so
  they stay in their deletion windows after the destroy. This is
  expected, and the sweep allows it.

## Security and Cost Implications

- Real AWS spend, inside a budget of USD 20 a month. The estimate in
  the 6.4 plan was USD 1.5–3 for a session of 3 hours or less; it stays
  `INFERRED` until the bill is measured.
- The EKS API endpoints are public but limited to the operator's /32
  (and, on the spoke, the hub's NAT IP), never wider than /16, as the
  variable validation already requires.
- Kubeconfigs, tfvars (which hold the budget e-mail and account IDs) and
  state live only under `.local/eks-sandbox/`, mode 600, and are never
  committed.
- No account ID is printed in full: logs show the last four digits.

## Validation Method

- `make eks-session-regression`, in `make validate`: 44 cases,
  covering every guard (each one mutation-tested by hand), the tfvars
  wiring and the aws-eks render.
- `check-terraform-offline` check 9f, with 11 regression cases in
  `check-terraform-offline-regression`.
- `terraform test`:
  - `envs/eks`: single-account hub, unknown or empty spoke keys refused,
    shared system nodes;
  - `envs/network`: one NAT IP;
  - `envs/sandbox-budget`: budget, alerts, refusals.
- Phase 6.4b: the session itself, with its evidence and measured bill
  added to the TAD.
