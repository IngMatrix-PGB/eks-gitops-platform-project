# ADR-0013: EKS Pod Identity and AWS Secrets Manager IaC (Phase 3.2)

**Status:** Accepted
**Date:** 2026-09-08

## Context

Following Phase 3.1 (Network/EKS IaC foundation, ADR-0012, merged via PR #12),
this phase designs and statically validates - never applies - the IAM/Pod
Identity/Secrets Manager/KMS layer per the canonical plan
(`.local/evidence/phase-3.2-pod-identity-secrets-manager-iac-plan.md`).
**`DESIGNED` / `STATICALLY VALIDATED` only - `NOT DEPLOYED`, `NOT VALIDATED
AGAINST A REAL AWS ACCOUNT`. Actual cost: USD 0.** Phase 3.2 creates IaC,
not resources; Phase 3.3 will implement the GitOps overlay that actually
migrates a `SecretStore` to this backend; the Kubernetes-provider local
backend continues running unchanged in the `kind` lab; no `SecretStore` is
migrated by this phase.

## Decision

### Module structure

`terraform/modules/eso-identity/` (a reusable child module, no state of its
own) is instantiated twice by a new root module, `terraform/envs/identity/`
(staging, production) - matching `terraform/modules/tags`'s own precedent.
Native AWS provider resources only (`aws_iam_role`, `aws_iam_policy_document`,
`aws_kms_key`, `aws_secretsmanager_secret`, `aws_secretsmanager_secret_policy`,
`aws_eks_pod_identity_association`) - `terraform-aws-modules/eks-pod-identity`
was explicitly evaluated and **not adopted**: for exactly two environments,
native resources plus one small local child module are sufficient, and the
external module's own bundled ESO-policy-generation feature would make the
actual granted permissions less directly auditable in this repository's own
tracked files than a hand-authored `data "aws_iam_policy_document"`.
`terraform/envs/identity` is discovered automatically by the existing,
unchanged `scripts/lab/terraform-root-modules.sh` pattern - no second
manually-maintained root list was introduced.

### ESO identity (ground truth, re-verified live against the cluster)

| Component | Pod namespace | ServiceAccount | Requires AWS |
|---|---|---|---|
| ESO controller - staging | `eso-staging` | `eso-staging-external-secrets` | Yes |
| ESO controller - production | `eso-production` | `eso-production-external-secrets` | Yes |
| Webhook (singleton) | `eso-staging` | `external-secrets-webhook` | No |
| Cert-controller (singleton) | `eso-staging` | `external-secrets-cert-controller` | No |

Only the two controllers receive a Pod Identity Association - enforced at
three independent layers: the child module's own variable validation
(`terraform/modules/eso-identity/variables.tf`), a repo-wide static
`check-terraform-offline.sh` rule (any literal association targeting either
singleton ServiceAccount fails closed, anywhere), and a `terraform test`
assertion. Staging and production can never accidentally share a role,
association, Secret, or KMS key - each is a fully independent child-module
instantiation, and a `check` block in `terraform/envs/identity/main.tf`
asserts the two environments' namespace/ServiceAccount pairs and secret
names are never identical.

### Trust policy

Exactly the official EKS Pod Identity trust policy (`pods.eks.amazonaws.com`
principal, `sts:AssumeRole`/`sts:TagSession` actions, re-verified against
AWS's docs 2026-09-08) - never an IRSA trust policy reused, never a
Federated/OIDC principal, never a wildcard action, never a hardcoded account
ID or real role ARN.

### IAM least privilege

Exactly ESO's own documented minimum policy
(`secretsmanager:GetSecretValue`/`DescribeSecret`/`GetResourcePolicy`/
`ListSecretVersionIds`) plus `kms:Decrypt` (required per AWS's own
documented "read a secret encrypted with a customer managed key" example,
since this design uses a customer-managed key) - scoped to exact
Terraform-resource-attribute ARNs, never a hand-built string, never
`secretsmanager:*`/`kms:*`/`Resource: "*"`. The KMS key's own administrative
(account-root) statement uses an enumerated list of key-management actions
rather than the literal `kms:*`, keeping the no-wildcard rule absolute
everywhere in this module with no special-cased exception.

### Secrets Manager and KMS

One `aws_secretsmanager_secret` (metadata only) and one customer-managed
`aws_kms_key` per environment - no `aws_secretsmanager_secret_version`
anywhere in this design, no exception, ever; the future value is
provisioned imperatively, out of Terraform state, in Phase 3.3. A resource-
based policy (`aws_secretsmanager_secret_policy`) additionally restricts the
secret's own `Principal` to exactly that environment's role ARN - a real,
additional isolation layer.

### Pod Identity Agent add-on ownership

Owned inside `terraform/envs/eks`'s existing `module "eks"` call, via that
module's own `addons` input (**not** `cluster_addons`, the plan's original
terminology - the real, downloaded module version 21.25.0 names this input
`addons`; corrected empirically, not assumed) - the only change this phase
makes to already-merged Phase 3.1 code. `most_recent` is explicitly set to
`false` (the module's own default is `true`) since the version is always
the caller-supplied, validated `pod_identity_agent_addon_version` variable
- no default, no static version table exists for this add-on, never a
hardcoded guess. No separate root, no ownership duplication: an add-on
cannot exist independent of its cluster.

### Allowlist adjustments (disclosed, not silently made)

`scripts/validate/check-terraform-offline.sh`'s AWS-data-source allowlist
gains `aws_iam_policy_document` - a data source confirmed (2026-09-08,
registry.terraform.io) to compute its `.json` output entirely client-side,
never contacting AWS under any circumstance, unlike `aws_availability_zones`
(explicitly, deliberately **not** added, per instruction - that data source
genuinely would call AWS in a real, future apply). The resource-block ban in
check 6a stays scoped to the root `terraform/` module only (unchanged from
Phase 3.1); four new repo-wide, no-exception rules were added: no
`aws_secretsmanager_secret_version` anywhere, no `secret_string`/
`secret_binary` argument anywhere, no `secretsmanager:*`/`kms:*`/bare-`*`
IAM action anywhere, and no literal Pod Identity Association targeting the
webhook/cert-controller singleton ServiceAccounts anywhere - each with an
accept/reject regression fixture pair in `tests/terraform/test-offline-
contract.sh` (42 total cases, up from 31).

### `mock_provider` limitation, confirmed a second time

`data "aws_iam_policy_document"`'s own `.json` output - despite being
computed entirely client-side, never calling AWS even under a real,
unmocked provider - is still replaced by `mock_provider "aws"`'s generic,
invalid-JSON placeholder unless explicitly overridden. Every such data
source in every test file is given an explicit `override_data` with a
minimal, syntactically valid placeholder policy document. To let
`terraform test` assert on the *real* computed action/resource lists (not
a hand-fed fixture value), the child module exposes them as plain Terraform
locals/outputs (`secretsmanager_actions`, `kms_actions`,
`permissions_resource_refs`) - values never touched by provider mocking at
all, since they involve no data source.

## Alternatives Considered

- **`terraform-aws-modules/eks-pod-identity`**: evaluated, not adopted (see
  above) - the plan itself named this as the one place worth stopping to
  ask before adding an external dependency; the instruction explicitly
  confirmed native resources are sufficient for two environments.
- **Widening the allowlist for `aws_availability_zones`**: explicitly
  rejected per instruction - `terraform/envs/network` continues taking
  availability zones as an explicit, no-default variable.
- **A single shared KMS key**: rejected (unchanged from the read-only plan)
  - one key per environment is the stronger isolation boundary, at
  negligible incremental cost.
- **`kms:*` for the key's own administrative statement**: rejected in favor
  of an enumerated action list, keeping the no-wildcard rule absolute with
  zero special-cased exception anywhere in this module.

## Consequences

### Positive

- Every isolation property demonstrated in this phase (distinct role/
  association/secret/KMS key per environment, no wildcard action, no
  webhook/cert-controller association) is enforced at three independent
  layers (Terraform-language validation, static repo-wide grep rule,
  `terraform test` assertion) - not just described in a comment.
- Adding a future `terraform/envs/<name>/` root remains automatic, with
  zero tooling change, confirmed again this phase via a dedicated
  regression fixture.

### Negative

- Hand-authoring `data "aws_iam_policy_document"` blocks (rather than
  using an external module's bundled policy generator) means slightly more
  IAM JSON in this repository's own tracked files - accepted for
  auditability.
- The static, grep-based enforcement rules for wildcard actions and
  webhook/cert-controller association exclusion only see literal strings in
  `.tf` source - a value supplied entirely through a variable/expression
  is not visible to this specific static check. The child module's own
  Terraform-language variable validation is the mechanism that actually
  enforces these properties for any variable-driven value; the static
  rules are a repo-wide textual backstop against a literal hardcoded
  regression, not a full data-flow analysis.

## Security and Cost Implications

Zero cost, zero AWS contact - re-proven this phase with
`AWS_SHARED_CREDENTIALS_FILE=/dev/null`/`AWS_CONFIG_FILE=/dev/null`/
`AWS_EC2_METADATA_DISABLED=true` across `terraform/envs/identity` and
`terraform/envs/eks` (the two roots this phase touches). If ever deployed:
~$2.80/month (2 Secrets Manager secrets + 2 KMS keys), on top of whatever
`envs/network`/`envs/eks` already cost when running - an estimate for
future reference, never an authorization to spend it.

## Validation Method

`make terraform-validate-offline` (fmt/init `-backend=false`/validate/test)
across all 5 discovered root modules; `make check-terraform-offline`/
`make check-terraform-offline-regression` (42 fixtures); `make check-
forbidden-terms-regression` (45 fixtures, unchanged from Phase 3.1); `make
validate`; the zero-AWS-contact proof above. No `terraform plan`/`apply`
against real AWS, no real backend, no AWS credential, no real account ID/
ARN anywhere in this phase's code.
