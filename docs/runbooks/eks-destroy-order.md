# Runbook: EKS Destroy Order

**`DESIGNED` / `NOT DEPLOYED` / `NOT VALIDATED AGAINST AWS` — `ACTUAL COST: USD 0`.**

This runbook documents the future order to tear down an `aws-eks`
environment created per
[eks-bootstrap-order.md](eks-bootstrap-order.md). **No step in this
document has been executed — do not execute any of these steps.** It
exists purely as an order-of-operations reference for a future,
separately authorized destroy operation.

## Order (documented, not executed)

1. **Pause GitOps.** Pause auto-sync on the `aws-eks`-profile root
   Application (and its generated `staging-aws`/`production-aws`
   Applications) so nothing re-reconciles mid-teardown.
2. **Retire workloads / `ExternalSecret`s.** Remove the workload
   Deployments/Jobs and their `ExternalSecret` resources for each
   environment being destroyed, in an order that lets each workload
   drain before its Secret source disappears.
3. **Confirm retained Secrets.** Before deleting anything in Secrets
   Manager, confirm — out-of-band, by an operator — that no other
   consumer (this project or otherwise) still depends on the same
   secret, since Secrets Manager secrets are never Terraform- or
   Git-owned (ADR-0013) and this runbook cannot itself enumerate every
   consumer.
4. **Retire Argo CD / ESO.** Uninstall the Argo CD and ESO releases from
   the isolated `aws-eks` kubeconfig only — never touch the `local-kind`
   lab's own Argo CD/ESO installation, which has an entirely separate
   kubeconfig, release, and lifecycle.
5. **Delete Pod Identity Associations.** Remove the
   `staging_association_id`/`production_association_id` associations
   (`terraform/envs/identity`) before deleting the roles or the cluster
   itself, so no association is left pointing at a deleted principal.
6. **Schedule or delete Secrets Manager secrets per separate
   authorization.** Secrets Manager secrets support a recovery window
   (`secret_recovery_window_in_days` in `terraform/envs/identity`) —
   scheduling deletion (not force-deleting) is the default-safe choice,
   and doing so at all requires its own explicit authorization separate
   from the general destroy authorization, since it is potentially
   unrecoverable after the window elapses.
7. **Delete KMS respecting pending deletion.** KMS keys
   (`staging_kms_key_arn`/`production_kms_key_arn`) also only support
   scheduled deletion with a waiting period
   (`kms_deletion_window_in_days`) — never immediate deletion — and must
   be scheduled only after step 6 confirms no secret still depends on
   the key for decryption.
8. **Delete EKS and nodes.** Run `terraform destroy` in
   `terraform/envs/eks`, removing the cluster, the Pod Identity Agent
   addon, and node capacity — only after steps 2–7 have removed every
   workload and identity association that depended on it.
9. **Delete the network.** Run `terraform destroy` in
   `terraform/envs/network`, removing the VPC/subnets/NAT — only after
   step 8 confirms no ENI or resource from the EKS root still occupies
   it.
10. **Delete the backend only with separate authorization.** The
    Terraform state backend (`terraform/bootstrap`) is explicitly out
    of scope for a routine destroy — it is shared infrastructure for
    every environment this project might ever provision, and its
    removal requires its own, separate, explicit authorization,
    independent of whatever authorized the rest of this teardown.
11. **Confirm residual cost.** After steps 1–9 (and 10, if separately
    authorized), confirm via the AWS account's own billing/cost tooling
    that no residual EKS, NAT, EC2, KMS-pending-deletion, or
    Secrets-Manager-pending-deletion cost remains accruing — this
    confirmation is the actual close of the destroy operation, not the
    `terraform destroy` exit code alone.

## What this runbook does not authorize

**No step above may be executed on the basis of this document alone.**
Every `terraform destroy` and every Secrets Manager/KMS deletion
scheduling action requires its own explicit, separate authorization
naming this runbook, at the time it is actually needed — this document
records order, not permission.
