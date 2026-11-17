# ADR-0018: Terraform plan and apply against a local AWS emulator

**Status:** Accepted
**Date:** 2026-11-17

Amends the offline contract of
[ADR-0011](0011-terraform-foundation.md): until this ADR, nothing in the
repository ran `terraform plan` or `terraform apply`. Everything else
ADR-0011 decides stays in force: no backend values, no committed
provider block, no AWS credentials or OIDC in any workflow, and no real
AWS resource without separate authorization.

## Context

The Terraform code is validated offline today (`fmt`, `validate`, and
`terraform test` with `mock_provider "aws"`). A mock proves the code's
own logic, but no request ever reaches an AWS API, so wrong argument
shapes, provider behavior on create, drift after apply and destroy
ordering stay untested until a real account. The TAD roadmap (5.2) asks
for `plan` on every PR and `apply` of the supported resource types
against a local emulator, with no AWS account involved.

Emulators considered (checked on 2026-11-17):

- **LocalStack:** since release 2026.03.0 its single image needs an auth
  token to start; the temporary bypass ended on 2026-04-06.
- **Moto server:** Apache-2.0, no account, published as
  `motoserver/moto`. Its coverage per AWS operation is uneven and has
  to be measured.

## Decision

- **Emulator:** moto server, pinned by digest
  (`motoserver/moto:5.2.5`), on loopback only.
- **One entry point:** `scripts/terraform/emulator.sh` (`make
  tf-emulator-up`, `tf-emulator-plan`, `tf-emulator-apply`,
  `tf-emulator-coverage`). It is the only place in the repository that
  runs plan, apply or destroy.
- **Scratch copies:** each root module is copied into a temporary
  directory, where the script generates the `provider "aws"` block and
  keeps local state. Neither is ever written into the repository, and
  the directory is deleted on exit.
- **Guards that keep it away from real AWS:**
  1. the endpoint must be `localhost` or `127.0.0.1`;
  2. Terraform runs under `env -i` with fixed fake credentials and the
     AWS config and credential files pointed at `/dev/null`, so no
     variable, profile or SSO session of the caller survives;
  3. the generated provider sends every service the code uses to the
     endpoint and sets `allowed_account_ids` to the emulator's account;
  4. before any plan, the endpoint must answer moto's own API and STS
     must report the emulator's account.
- **Cycle per root:** `plan`, then `apply`, then a second `plan
  -detailed-exitcode` that must show no changes, then `destroy`. Each
  root starts from an emptied emulator.
- **Fixtures:** `terraform/emulator/<root>.tfvars` holds fabricated
  variable values. Account IDs are placeholders resolved at runtime, so
  no twelve-digit literal is committed.
- **Coverage is measured, not assumed:** `terraform/emulator-coverage.tsv`
  records, per root, the result of each step and the emulator gaps that
  explain anything short of a full cycle.
- **Contract (`check-terraform-offline`):**
  - check 9 skips exactly the emulator script and calls to it;
  - check 9b fails if the script loses any guard above, its digest pin,
    or its identity check before plan/apply, or gains a backend;
  - check 9c rejects any other script, Makefile or workflow that writes
    a `provider "aws"` block.

## Alternatives Considered

- **LocalStack.** Rejected: it needs an auth token since 2026.03.0, so CI
  would carry an external account's secret; pinning an older community
  image freezes a security-relevant dependency.
- **Newer no-auth emulators.** Rejected for now: vendor claims only, no
  track record. Reconsider if moto's coverage proves too thin.
- **A real AWS plan through OIDC.** Out of scope: it needs an AWS
  account, a role and explicit authorization. It would be its own phase.
- **A committed provider block or override file.** Rejected: the
  repository would then hold a runnable provider configuration, which
  the offline contract exists to prevent.

## Consequences

- Terraform changes can be applied and destroyed before any account
  exists, and drift after apply becomes visible.
- Some roots do not complete a full cycle because moto lacks or
  outdates an API. The coverage table names each gap; those roots stay
  plan-only (or partial) until the emulator covers them.
- A new resource type needs a coverage measurement before it can count
  as applied.

## Security and Cost Implications

- No credentials, no account and no network path to AWS: every request
  goes to a container on loopback, and the provider refuses any account
  but the emulator's.
- The emulator image is a new dependency, pinned by digest.
- Cost: USD 0.

## Validation Method

- `make tf-emulator-coverage` on the full tree, recorded in
  `terraform/emulator-coverage.tsv`.
- `make check-terraform-offline-regression`: the real script is accepted,
  and one mutated copy per guard is rejected, as is a plan or apply in
  any other script and a provider block written anywhere else.
- Runtime refusals: a non-loopback endpoint and a loopback server that
  is not the emulator are both refused before Terraform runs.
