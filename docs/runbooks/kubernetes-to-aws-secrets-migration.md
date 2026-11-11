# Runbook: Kubernetes-Provider to AWS-Secrets-Manager Migration

**`DESIGNED` / `NOT DEPLOYED` / `NOT VALIDATED AGAINST AWS` — `ACTUAL COST: USD 0`.**

This runbook documents how a future, already-`aws-eks`-bootstrapped
environment would migrate its `ExternalSecret` backend from the
`kubernetes` provider (`charts/standard-workload/values-{dev,uat,
prod}.yaml`, ADR-0010) to the `aws` provider (`values-{dev,uat,
prod}-aws.yaml`, ADR-0013, ADR-0014) with zero workload downtime.
**No step has been executed.** It requires an `aws-eks`-profile cluster
to already exist per
[eks-bootstrap-order.md](eks-bootstrap-order.md) — which itself has not
been executed either.

## Precondition

The target environment's Application is already reconciling under the
`aws-eks` profile (post [eks-bootstrap-order.md](eks-bootstrap-order.md)
step 10), with its `kubernetes`-provider `ExternalSecret` still the one
actually populating the workload's mounted Secret. This runbook migrates
the *backend*, never the workload's own consumption of the resulting
Kubernetes `Secret` — the workload never changes.

## Order (dev first, then uat, then prod — always)

1. **Activate in dev first, never uat or prod first.** Confirm
   dev's Pod Identity Association
   (`terraform/envs/identity`'s `dev_association_id` output) and
   Secrets Manager secret (`dev_secret_arn`) exist and are
   `Active`, per Terraform apply already run in
   [eks-bootstrap-order.md](eks-bootstrap-order.md) step 3.
2. **Populate the secret payload out-of-band.** Write the actual secret
   value into the Secrets Manager secret at `dev_secret_name`
   (`eks-gitops-platform-project/dev/backend`) using an operator's
   own AWS access — never Terraform, never Git, per ADR-0013's ownership
   boundary (Secret payload = "Out-of-band operation, never Terraform,
   never Git").
3. **Hash as evidence, not payload.** Before and after switching,
   record only a SHA256 of the *rendered Kubernetes Secret's* data keys
   and byte-length (never the plaintext value) as migration evidence —
   the same non-secret-evidence principle `eks_identity_fingerprint()`
   already uses for cluster identity.
4. **Cut over the chart values.** For dev only, change
   `charts/standard-workload`'s active values file for that environment
   from `values-dev.yaml` to `values-dev-aws.yaml` (both already
   exist and are offline-validated — this step only changes which one
   the `aws-eks`-profile Applications actually consume; `provider:
   "kubernetes"` vs `provider: "aws"` is the only field that changes
   semantics; `secretStoreName` also changes, from
   `"dev-kubernetes-backend"` to `"dev-aws-backend"`, since the
   two providers are deliberately never the same `SecretStore` object).
5. **Stable destination secret.** Confirm the destination Kubernetes
   `Secret` name and the keys the workload mounts are unchanged across
   the cutover — only the `ExternalSecret`'s upstream backend changes,
   never the Secret's own name/namespace/keys the workload reads.
6. **Argo CD pause, then resume.** Pause auto-sync on the affected
   Application before the values cutover (to avoid a mid-flight partial
   reconcile), apply the values change, confirm the new
   `ExternalSecret`/`SecretStore` reconcile to `Ready` and the
   destination Secret's hash (step 3) matches the pre-cutover value,
   then resume auto-sync.
7. **Safe retirement of the `kubernetes`-provider backend.** Only after
   dev has run stably on the `aws` provider, retire dev's
   `kubernetes`-provider `SecretStore`/source Secret
   (`local-backend-dev`) — mirroring the same safe-retirement
   pattern already used for the root Application in Phase 2.6.3
   (never delete a backend that is still the live source of truth for
   any environment).
8. **Repeat for uat, then for prod**, each only after the previous
   environment has been stable on the `aws` provider for an
   operator-defined soak period — this runbook
   does not itself define that period; it is a future operational
   decision, not a value invented here.

## Rollback

At any point before step 7 (retirement) for a given environment,
rollback is simply reverting that environment's chart values file
selection back to the `kubernetes`-provider file
(`values-{dev,uat,prod}.yaml`) and letting Argo CD reconcile —
the `kubernetes`-provider backend is never touched or retired until
step 7 explicitly authorizes it, so rollback before that point requires
no data recovery, only a Git revert and a resume of auto-sync.

## What this runbook does not authorize

Writing a real secret value into Secrets Manager, running any
`terraform apply`, or applying any manifest against a real cluster —
all remain out of scope until the environment's `aws-eks` bootstrap
(per [eks-bootstrap-order.md](eks-bootstrap-order.md)) is itself
separately authorized and executed.
