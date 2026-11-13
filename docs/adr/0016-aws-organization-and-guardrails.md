# ADR-0016: AWS organization, accounts and guardrails

**Status:** Accepted
**Date:** 2026-11-13

Amends the AWS section of
[ADR-0015](0015-hub-and-spoke-environment-model.md). Everything ADR-0015
decides that this ADR does not explicitly change remains in force:
one AWS account per workload environment, the hub never runs
application workloads, the first real deployment is a single sandbox
account, and no AWS resource is created without separate authorization.

## Context

ADR-0015 chose one account per environment (`management`, `dev`, `uat`,
`prod`) under one AWS Organization, with guardrails, threat detection,
configuration recording and budgets defined in Terraform. Turning that
into code raises three questions it did not answer:

- **Which account administers the security services.** GuardDuty,
  Security Hub, AWS Config and IAM Access Analyzer each accept one
  delegated-administrator account for the organization. If that is the
  organization's management account, the account that can change every
  guardrail also owns every finding about itself.
- **Where the hub cluster lives.** ADR-0015 calls the hub's environment
  `management`. Putting the hub in the organization's management account
  would put a workload cluster in the one account service control
  policies never apply to.
- **How Terraform reaches several accounts.** This repository's offline
  contract (`scripts/validate/check-terraform-offline.sh`) forbids an
  operative `provider "aws"` block: every root receives its credentials
  from the runner. Provider aliases with `assume_role` would break that
  contract and couple every account into a single state.

## Decision

- **Five member accounts plus the organization's management account.**
  - **Management account (organization only):** the organization,
    organizational units, service control policies, the organization
    trail, delegated-administrator registrations and the consolidated
    budget. No workloads and no hub cluster.
  - **`security`** (OU Security): delegated administrator for GuardDuty,
    Security Hub, AWS Config and IAM Access Analyzer; owns the
    organization trail's S3 bucket and KMS key.
  - **`platform`** (OU Platform): the hub (ADR-0015's `management`
    environment) and, from Phase 3.4.3, the container registry.
  - **`dev`, `uat`** (OU Workloads/NonProd) and **`prod`** (OU
    Workloads/Prod).
- **One Terraform root per account role**, each applied with that
  account's own credentials; no provider aliases, one state per account.
  `terraform/envs/org` is applied in the management account and
  `terraform/envs/security` in the security account. Roots that repeat
  per account (Phases 3.4.2–3.4.4) take the environment as a variable.
- **Service control policies**, built as JSON with `jsonencode()` in
  `terraform/modules/scp` so their exact content is tested:
  - **Region guardrail** (organization root): deny every action outside
    `allowed_regions` except AWS's documented list of global services,
    exempted through `NotAction`. No regional service is ever exempted
    as a whole.
  - **Member hardening** (organization root): deny
    `organizations:LeaveOrganization` and every root-user action, with
    no exemption; deny disabling EBS encryption by default and changing
    the S3 account public access block, except for the account access
    role.
  - **Security-services protection** (OUs Platform and Workloads only):
    deny disabling or blinding GuardDuty, Config, CloudTrail, Security
    Hub and Access Analyzer, except for the account access role. It is
    not attached to the Security OU, whose delegated administrator must
    manage those services.
  - Service control policies never apply to the management account.
    That account's protection is limited access, not a policy.
- **Organization-wide security services**, administered from `security`:
  - GuardDuty auto-enabled for all members, with S3, EKS audit-log and
    runtime protection (EKS add-on managed). EBS malware scanning is
    left off because it is billed per scan.
  - Security Hub with central configuration: one policy on the
    organization root enables the service with the AWS Foundational
    Security Best Practices and CIS 3.0 standards.
  - A Config aggregator over the allowed regions. The per-account
    recorders arrive with the account baseline (Phase 3.4.2).
  - IAM Access Analyzer with the organization as its zone of trust.
- **One organization trail**: multi-region, global events included, log
  file validation on. It is created in the management account and
  delivers to the security account's bucket, encrypted with that
  account's key. The bucket and key policies admit exactly that trail.
- **Apply order** (never run by this repository):
  1. `envs/org` without the trail.
  2. `envs/security`, using `envs/org`'s outputs.
  3. `envs/org` again, with the bucket and key, which creates the trail.
- **A consolidated monthly cost budget** for the organization, with
  alerts at 80 % and 100 % actual and 100 % forecasted spend.
  Per-account budgets come with the account baseline.

## Alternatives Considered

- **Four accounts with security administration in the management
  account.** Rejected: one account would hold both the power to change
  every guardrail and every finding about it, and AWS recommends against
  delegating these services to the management account.
- **The hub in the organization's management account.** Rejected: a
  workload cluster would run in the one account no service control
  policy applies to.
- **One multi-account root with provider aliases.** Rejected: it breaks
  the offline contract and puts every account's resources in one state,
  so one bad apply could reach every account.
- **Building SCPs with `aws_iam_policy_document`.** Rejected for SCPs:
  under `mock_provider` its output is a placeholder, so the tests could
  not assert the policy content. `jsonencode()` keeps the content
  testable without any provider.

## Consequences

- Five member accounts to create, each with a unique root mailbox
  supplied at apply time; none is committed.
- The organization trail needs two applies of `envs/org`, documented
  above.
- The account access role is the only principal exempted from the
  hardening and security-services guardrails, because the account
  baseline is applied through it. Who can assume it is therefore the key
  control, and it must stay limited.
- The region guardrail's `NotAction` list contains entries such as
  `kms:*`. These are exemptions from a deny, not grants. The offline
  check's wildcard rule masks exactly that list in exactly
  `terraform/modules/scp/main.tf`, and its regression suite proves that
  any other occurrence is still rejected.

## Security and Cost Implications

Security-positive: account boundaries isolate environments; guardrails
prevent leaving the organization, root-user use, use of unapproved
regions, and switching off detection; and findings land in an account
the workload accounts cannot administer.

Cost (`INFERRED` from public pricing, nothing applied, current cost
USD 0):

| Item | Cost |
|---|---|
| Organizations, OUs, SCPs, accounts and budgets | No charge (the first budgets per account are free) |
| First organization trail of management events | No charge beyond S3 storage |
| GuardDuty and Security Hub | Per events analyzed and per checks; GuardDuty's EKS runtime protection is the main variable |
| AWS Config | Charged per item recorded; the recorders arrive in 3.4.2 with an explicit resource-type list |

## Validation Method

- `terraform test` in `terraform/envs/org` (11 runs) and
  `terraform/envs/security` (8 runs) with `mock_provider "aws"`:
  - accounts are in their OUs;
  - each guardrail is attached exactly where intended (never the
    security-services guardrail on the Security OU);
  - the exact SCP content (region condition, global exemptions, no
    regional service exempted, deny-only, the 5,120-character limit,
    the root-user deny with no exemption);
  - every delegated administrator is the security account;
  - the trail's properties, with bucket and key policies scoped to that
    one trail;
  - GuardDuty and Security Hub organization settings, the Config
    aggregator and the Access Analyzer zone of trust;
  - rejection of invalid inputs.
- Two mutation checks were run during implementation, each caught by a
  failing test: attaching the security-services guardrail to the
  Security OU, and exempting `ec2:*` from the region guardrail.
- `make terraform-validate-offline`, `make check-terraform-offline` and
  `make check-terraform-offline-regression`.
- No real `plan` or `apply`. A real apply needs separate, explicit
  authorization (`AGENTS.md`).

## Amendment (Phase 3.4.2, 2026-11-13): account baseline

`terraform/envs/account-baseline` is applied once in each member account
(`account_role` is one of security, platform, dev, uat, prod), through
the account access role, the only principal the hardening and
security-services guardrails exempt.

- **Regions without provider aliases.** In `hashicorp/aws` 6.x every
  regional resource takes a `region` argument. The baseline creates its
  regional controls with `for_each` over `allowed_regions`, so it stays
  one root and one state per account, and the offline contract still
  holds.
- **AWS Config:**
  - One recorder per allowed region, recording an explicit list of
    resource types (EKS, EC2 and networking, Auto Scaling, ELBv2, S3,
    KMS, ECR, Secrets Manager, Lambda, SQS, EventBridge, CloudTrail,
    Config compliance), never "all supported", since cost scales with
    what is recorded.
  - The global IAM types are recorded only in `home_region`, so each is
    recorded once.
  - `CONTINUOUS` recording and 7-year retention in `prod`; `DAILY` and
    365 days everywhere else.
  - Every account delivers under `config/<account_role>/` to one central
    bucket in the security account, encrypted with a dedicated key. The
    bucket and key admit AWS Config only for this organization
    (`aws:SourceOrgID`).
- **EC2 defaults per region:** EBS encryption by default, using the
  AWS-managed `aws/ebs` key, and IMDSv2 required account-wide (hop limit
  2; node groups and Karpenter set their own launch templates in 3.4.3).
- **S3** account-level public access block with all four flags.
- **Monthly budget per account**, with alerts at 80 % and 100 % actual
  and 100 % forecasted.
- **Not created per account:** GuardDuty and Security Hub (the
  organization auto-enables them from `security`) and IAM Access
  Analyzer (the organization analyzer already covers every member; the
  unused-access analyzer is billed per role and user).
- **Validation:**
  - `terraform test` in `account-baseline` (9 runs) and in `security`
    (10 runs, including the Config bucket).
  - A cross-check in `envs/org`'s tests that no service control policy
    denies an action the baseline needs without exempting the access
    role.
  - Three mutation checks were run, each caught by a failing test: IAM
    types recorded in every region, an S3 account block flag set to
    false, and an SCP that denies the baseline's
    `s3:PutAccountPublicAccessBlock` without the exemption.

## Amendment (Phase 3.4.3b, 2026-11-13): container registry

`terraform/envs/registry` is applied in the `platform` account. It
creates one ECR repository per workload image:

- `IMMUTABLE` tags, so a release tag never moves to a different image;
- scan on push (basic scanning; enhanced scanning is evaluated with the
  image CI in Phase 5.1);
- KMS encryption;
- never force-deleted.

A lifecycle policy expires untagged images after 7 days and keeps the
last 30 `v*` releases. The repository policy lets only the `dev`, `uat`
and `prod` accounts pull (the three pull actions, the three account
roots, conditioned on `aws:PrincipalOrgID`), with no `*` principal and
no push or delete action. Images are pushed only from the platform
account. `terraform test` runs 8 cases; three mutation checks (a
mutable repository, `ecr:*`, a `*` principal) are each caught by a
failing test.
