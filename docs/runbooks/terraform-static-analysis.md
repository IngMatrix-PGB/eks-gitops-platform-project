# Runbook: Terraform static analysis

Runs `trivy config` on the tracked Terraform code
([ADR-0019](../adr/0019-terraform-static-analysis.md)). It needs no AWS
account and reads only the public Terraform Registry for the pinned
modules.

## Prerequisites

- `make tools-install` (pinned trivy).
- `jq` and `git`.

## Steps

1. Run the scan: `make tf-static`. The `validate` workflow runs the
   same target on every PR and push to `main`.
2. Read the result:
   - MEDIUM and LOW findings are listed first; they are reported, not
     gated.
   - The run fails on a HIGH or CRITICAL finding that
     `terraform/.trivyignore.yaml` does not accept.
   - The full report, every severity, is in
     `.tools/out/terraform/trivy-config.json`.
3. For a new HIGH or CRITICAL finding, fix the code first. Accept it
   only when the configuration is intended, by adding one entry to
   `terraform/.trivyignore.yaml`:
   - `id`: the trivy check ID, for example `AWS-0132`;
   - `paths`: the exact file as trivy names it in the report (a module
     file is named like `terraform-aws-modules/eks/aws/main.tf`); no
     globs;
   - `expired_at`: at most six months ahead;
   - `statement`: why the finding does not apply here, naming the ADR.
4. When an exception expires, the scan fails. Fix the code, or renew the
   entry with a new date and a statement that still holds.
5. When a fix removes a finding, the scan fails with "stale exception".
   Delete that entry.

## Verification

- `make tf-static` ends with `tf-static: OK` and the number of accepted
  findings.
- `make check-terraform-offline` reports that the static-analysis script
  keeps its gate.

## Rollback

Revert the commit. The scan writes only under `.tools/out/terraform/`
and changes no infrastructure.
