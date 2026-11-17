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
5. Stop the emulator: `make tf-emulator-down`.

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
