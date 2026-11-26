# Runbook: Human access to AWS and time-bound elevation

People reach the AWS accounts through IAM Identity Center
([ADR-0025](../adr/0025-lab-identity-provider.md), Phase 4d). The access
is code in `terraform/envs/identity-center`. This repository only tests
that code offline: nothing here has been applied, so every step that
changes AWS is for a real deployment, run by its operator with an
explicit go.

## Who has what, standing

| Group | Permission set | Accounts |
|---|---|---|
| platform-admins | PlatformAdmin (AdministratorAccess, 1 h) | platform, dev, uat |
| platform-admins | ReadOnly (ReadOnlyAccess + SecurityAudit, 4 h) | security, prod |
| developers-dev | Developer (ViewOnlyAccess + describe the project's EKS clusters, 1 h) | dev |
| developers-uat | Developer | uat |
| auditors | ReadOnly | every account |
| breakglass | none | none |

Nobody has standing admin, developer or break-glass access to prod.
People join groups in Identity Center itself, outside Terraform.

Inside EKS, two optional access entries in `terraform/envs/eks` give
the Identity Center roles their Kubernetes rights:

- `developer_principal_arn`: `AmazonEKSViewPolicy` in the environment's
  own namespace (dev or uat only);
- `readonly_principal_arn`: `AmazonEKSViewPolicy` on the whole cluster.

Pass the role ARN **without its path**:
`arn:aws:iam::<account>:role/AWSReservedSSO_Developer_<random>`, not
`.../role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_...`.
EKS access entries refuse the path, and the variable's validation
refuses it first.

## Asking for more: an elevation

An elevation is a pull request that adds one entry to
`terraform/envs/identity-center/elevations.auto.tfvars.json`:

```json
{
  "elevations": [
    {
      "group": "breakglass",
      "permission_set": "BreakGlass",
      "account": "prod",
      "starts_at": "2026-11-25T14:00:00Z",
      "expires_at": "2026-11-25T16:00:00Z",
      "reason": "incident: prod deployments stuck, link to the incident"
    }
  ]
}
```

- Times are UTC with a `Z`.
- An entry lasts at most 8 hours.
- The reason has at least 10 characters.
- There is at most one entry per group, permission set and account, and
  never one that repeats standing access.

Terraform's validation refuses anything else (`terraform test` covers
each rule). `make check-elevations` also fails, in every pull request,
when an entry has expired or starts more than 7 days ahead.

The steps:

1. Open the pull request with the entry; a second person reviews it.
2. After the merge, the operator plans and applies
   `terraform/envs/identity-center`. The assignment exists from then on.
3. When the work is done, or at the latest at `expires_at`, open a pull
   request that removes the entry, and apply it. That apply removes the
   assignment from AWS.

`expires_at` does not remove anything in AWS by itself. It makes CI fail
until the entry is removed, so an expired grant cannot sit in `main`
unnoticed. Removing it from AWS is always the apply of step 3.

## Checks

```bash
make check-elevations
```

```bash
make check-elevations-regression
```

```bash
make terraform-validate-offline
```

The last one runs `terraform test` in every root, including
`identity-center` (permission sets, standing access, every elevation
rule) and `eks` (the two access entries).
