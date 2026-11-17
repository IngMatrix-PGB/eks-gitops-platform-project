# ADR-0019: Static analysis of the Terraform code

**Status:** Accepted
**Date:** 2026-11-17

## Context

The Terraform code is validated offline (`fmt`, `validate`, `terraform
test` with a mock provider) and, since
[ADR-0018](0018-terraform-against-a-local-aws-emulator.md), applied
against a local emulator. Neither looks for insecure configuration: an
open API endpoint, an unencrypted bucket or a missing log would pass
both. The roadmap (5.2) asks for static analysis on every PR.

`trivy` is already pinned and checksum-verified for the image supply
chain ([ADR-0017](0017-image-supply-chain.md)), and its `config` scanner
reads Terraform, including the registry modules the code calls.

Measured on 2026-11-17 with trivy 0.76.1 on the tracked files: 4
HIGH/CRITICAL findings, 5 MEDIUM and 3 LOW. All four HIGH/CRITICAL are
in this repository's configuration, two of them through inputs to the
upstream EKS module.

## Decision

- **Tool:** `trivy config`, from the pinned binary. No new tool.
- **One entry point:** `scripts/terraform/static-analysis.sh` (`make
  tf-static`), run by the `validate` workflow on every PR and push to
  `main`.
- **Scope:** a scratch copy of the files Git tracks under `terraform/`,
  with the Terraform scanner only. A local `.terraform/` cache, state or
  the upstream modules' own examples never change the result. trivy
  resolves the pinned registry modules and evaluates them with this
  repository's inputs.
- **Rules:** the checks embedded in the pinned binary
  (`--skip-check-update`, empty cache). The result changes when
  `tool-versions.txt` changes, never because a new rule bundle was
  published.
- **Gate:** any HIGH or CRITICAL finding fails. MEDIUM and LOW are
  reported in the job log and recorded in
  `.tools/out/terraform/trivy-config.json`, not gated.
- **Exceptions:** `terraform/.trivyignore.yaml`, one entry per finding,
  each with the check ID, the exact file (no globs), an expiry date and
  a statement. An expired entry fails, and so does an entry whose
  finding no longer exists, so the file cannot keep stale exceptions.
- **Accepted on 2026-11-17, all expiring on 2027-05-17:**
  - AWS-0040, EKS public endpoint: needed before a VPN exists; limited
    to `eks_public_access_cidrs`, private access on.
  - AWS-0104, node egress to any address: from the upstream module;
    nodes reach AWS APIs and registries through NAT, with no VPC
    endpoints yet.
  - AWS-0019, Config aggregator not on all regions: the region SCP
    denies every other region (ADR-0016).
  - AWS-0132, state bucket on the AWS managed KMS key: a customer
    managed key is worth it only with a key policy limited to the
    Terraform runner role, which comes with the real-AWS phase.
- **Fixed instead of accepted:** `eks_public_access_cidrs` promised to
  fail closed but had no validation. It now rejects an empty list,
  anything that is not IPv4, and any range wider than /16, with four
  `terraform test` cases.
- **Contract (`check-terraform-offline`, check 9d):** the script keeps
  the HIGH,CRITICAL threshold, `--exit-code 1`, the exception file,
  `--skip-check-update`, the Terraform-only scope on tracked files, the
  expired and stale checks, the `make tf-static` target and the
  `validate` step.

## Alternatives Considered

- **tflint.** Deferred: it downloads rule plugins from GitHub at run
  time, a supply-chain surface. Reconsider once plugins can be pinned by
  checksum in `tool-versions.txt`.
- **Checkov.** Rejected: a second scanner with its own Python
  dependency tree, for findings largely the same as trivy's.
- **The plain `.trivyignore` format.** Rejected: an ID accepted there is
  accepted in every file, so a new public bucket would pass under an
  exception written for a different one. The YAML format scopes each
  exception to one file.
- **Excluding the downloaded modules (`--tf-exclude-downloaded-modules`).**
  Rejected: two of the four findings come from this repository's inputs
  to the EKS module and would be hidden.
- **Gating on MEDIUM.** Not now: the five MEDIUM findings are logging
  and IAM pass-role scoping choices that need cost and design decisions
  of their own. They stay visible in every run.

## Consequences

- A PR that adds a HIGH or CRITICAL misconfiguration fails `validate`
  unless it also adds a dated, justified, single-file exception, which
  is reviewed with the code.
- Each exception has to be revisited by its expiry date.
- Upgrading trivy can add findings; the upgrade PR has to fix or accept
  them.

## Security and Cost Implications

- The scan reads only the tracked Terraform files and the public
  Terraform Registry for the pinned modules. No AWS access.
- Cost: USD 0; about ten seconds of CI time.

## Validation Method

- `make tf-static` on the full tree: passes with four accepted findings.
- Runtime mutations, each failing: an expired date, a removed exception,
  a glob path, a path that no longer matches, a short statement.
- `make check-terraform-offline-regression`: the real script is
  accepted; a higher threshold, no `--exit-code 1`, an added
  `--exit-code 0`, downloaded rules, no stale check, no `make` target and
  no `validate` step are each rejected.
- `terraform test` in `terraform/envs/eks`: open, wide, empty and IPv6
  public access lists are rejected.
