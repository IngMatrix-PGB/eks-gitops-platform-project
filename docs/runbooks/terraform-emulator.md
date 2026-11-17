# Runbook: Terraform against the local AWS emulator

Runs the Terraform root modules against moto on loopback
([ADR-0018](../adr/0018-terraform-against-a-local-aws-emulator.md)). No
AWS account, credential or network path to AWS is involved.

## Prerequisites

- `make tools-install` (pinned Terraform).
- Docker, for the emulator container.

## Steps

1. Start the emulator: `make tf-emulator-up`. It listens on
   `http://localhost:5050` and the command fails unless the endpoint
   answers as the emulator with the emulator's account.
2. Plan every root: `make tf-emulator-plan`, or one root with
   `make tf-emulator-plan ROOT=terraform/envs/registry`.
3. Full cycle (plan, apply, re-plan that must be empty, destroy):
   `make tf-emulator-apply ROOT=terraform/envs/registry`.
4. Measure coverage for every root: `make tf-emulator-coverage`. Results
   go to `.tools/out/terraform/summary.tsv` and one log per root. Copy a
   changed result into `terraform/emulator-coverage.tsv` together with
   the gap that explains it.
5. Check that every root still matches the table, as CI does:
   `make tf-emulator-ci`. It fails when a root's result differs from its
   row in `terraform/emulator-coverage.tsv`, in either direction, and
   writes `.tools/out/terraform/summary.md`.
6. Stop the emulator: `make tf-emulator-down`.

## In CI (Phase 5.2c)

`.github/workflows/terraform.yml` runs steps 1, 5 and 6 on every PR and
push to `main` that touches `terraform/`, `scripts/terraform/`, the
pinned tool versions, the `Makefile` or the workflow itself. It is
read-only and has no AWS credential or OIDC token. The job summary shows
the result per root; on failure, the end of each root's log is printed.

When `make tf-emulator-ci` fails:

- **A root got worse:** the change broke something the emulator covered.
  Read that root's log and fix the code.
- **A root got better** (a newer emulator, or an API now avoided): update
  its row and its gaps in `terraform/emulator-coverage.tsv`.
- **A new root:** add its row and a `terraform/emulator/<root>.tfvars`.

## Notes

- Each root starts from an emptied emulator and runs in a scratch copy;
  the generated provider and the state are deleted on exit.
- Variable values come from `terraform/emulator/<root>.tfvars`. A new
  required variable needs a fabricated value there.
- `localhost` is used instead of `127.0.0.1` because S3 Control requests
  go to `<account>.<endpoint host>`, and only `*.localhost` resolves to
  loopback.
- An API the emulator lacks makes the provider retry; each step stops
  after `TF_EMULATOR_STEP_TIMEOUT` seconds (default 240) and is
  reported as `timeout`.
- The endpoint can only be `localhost` or `127.0.0.1`; anything else is
  refused before Terraform runs.
