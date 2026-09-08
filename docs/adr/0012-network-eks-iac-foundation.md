# ADR-0012: Network and EKS IaC foundation (Phase 3.1)

**Status:** Accepted
**Date:** 2026-09-05

## Context

Following Phase 2.7.1 (Terraform toolchain and offline validation, ADR-0011,
merged via PRs #10/#11), this work continues the canonical plan
(`.local/evidence/phase-2.7-eks-aws-foundation-plan.md`) toward a real VPC
and EKS cluster - designed, statically validated, never applied. A
read-only planning pass (`.local/evidence/phase-2.7.2-network-eks-iac-plan.md`)
surfaced several divergences between that plan's stated intent and the
tooling merged in Phase 2.7.1, which this ADR resolves.

### Phase numbering

The repository's own long-standing Technical Architecture Document roadmap
(unchanged across many prior revisions, predating any Phase 2.7 work)
reserves "Phase 2.7" for an unrelated "Multicluster profile" item and calls
the Terraform/EKS work "Phase 3." The canonical Phase 2.7 plan document and
Phase 2.7.1's own PRs used "Phase 2.7" regardless. **Resolved: this and all
subsequent Terraform/EKS/Pod-Identity/Secrets-Manager work is canonical
Phase 3, tracked from this point as Phase 3.1 onward.** PR #11 / Phase
2.7.1 is not renamed or rewritten - it stands as the pre-Phase-3 offline-
enforcement prerequisite this phase builds on. Broader README/TAD
reconciliation of the numbering (and Phase 2.7.1's own historical labeling)
is deliberately deferred to the plan's already-designated documentation
subphase, not addressed here beyond this ADR's own record of the decision.

## Decision

### Multi-root-module discovery

The canonical plan requires several independent Terraform root modules
(`terraform/`, `terraform/bootstrap/`, one directory per
`terraform/envs/*`), each with its own state/pins/lock file - Phase 2.7.1's
tooling assumed exactly one root. `scripts/lab/terraform-root-modules.sh` is
the single source of truth for "what are the root modules," discovering
them by **directory structure alone** (never a manually-maintained list,
never the presence of any specific file inside a candidate) - a directory
matching the structural pattern is discovered and validated even if it is
missing its own `versions.tf`, which then fails that specific check rather
than being silently skipped. Both `scripts/validate/check-terraform-
offline.sh` and the Makefile's `terraform-init`/`terraform-validate`/
`terraform-test`/`terraform-validate-offline` targets source/invoke this
one script rather than re-implementing discovery.

### Backend-block relaxation

The canonical plan's own network/foundation design calls for an
empty/partial backend block (`backend "s3" {}`, real bucket/key/region
supplied later via `-backend-config`) in every root module except
`bootstrap/`. `check-terraform-offline.sh`'s backend check is now
block-aware (not a per-line pattern): a backend block is accepted only if
its body contains nothing but blank lines/comments; any real attribute
(`bucket`, `key`, `region`, `dynamodb_table`, `profile`, `access_key`, ...)
still fails closed. `terraform/bootstrap/` itself carries no backend block
at all, ever - it is the one root module that always uses local state,
since it creates the very S3 bucket every other root module's backend
would eventually point at. `terraform/envs/network/` and
`terraform/envs/eks/` currently carry **no** backend block either (the
allowance exists for when a real, separately authorized apply-capable
phase adds one) - every root module validates today exclusively via
`terraform init -backend=false`.

### Resource-ban scoping

Phase 2.7.1's checker banned any `resource "aws_*"` block repo-wide,
correct for that phase's pure toolchain-smoke-test scope. Phase 3.1's
`terraform/bootstrap/` and `terraform/envs/*/` modules exist specifically
to hold real (never-applied) AWS resource blocks - `aws_s3_bucket` in
`bootstrap/`, VPC/EKS resources (via community modules) in `envs/network/`
and `envs/eks/`. The ban is now scoped to the root `terraform/` module only
(`terraform/*.tf` directly), which stays permanently resource-free.
Inertness is enforced by the other checks (no configured backend, no
operative `provider "aws"` block, no real `plan`/`apply`, no credentials),
never by pretending no resource can be written anywhere.

### Lock-file exception generalized

Every root module's own `terraform init`-generated `.terraform.lock.hcl`
needs the same masking `check-forbidden-terms.sh` already applied to the
single original lock file (a real, externally-fixed provider checksum can
coincidentally contain a 12+ digit run). The exception generalizes from an
exact path match to any `terraform/.../.terraform.lock.hcl`, still scoped
by the same block-structural state machine (only a `zh:`/`h1:` line
genuinely inside a `hashes = [ ... ]` array is masked) and still requiring
the path to genuinely start with `terraform/` and end in
`.terraform.lock.hcl` - never a lookalike path.

### Availability zones as an explicit variable

Per explicit instruction, `terraform/envs/network/`'s `availability_zones`
is a required `list(string)` variable with no default - this module never
calls `data "aws_availability_zones"` to derive it automatically, keeping
`check-terraform-offline.sh`'s AWS-data-source allowlist unwidened
(`aws_caller_identity`, `aws_region` only).

### Test-file placement corrected from the canonical plan's literal path

The canonical plan's own path list named `terraform/tests/network.tftest.hcl`
and `terraform/tests/eks.tftest.hcl` - a single shared top-level tests
directory. Terraform's own `terraform test` command resolves test files
from a `tests/` subdirectory of the module under test by default; a shared
top-level directory would make every root module's `terraform test`
attempt to run every other root module's test file, referencing variables
and resources that do not exist in that root. Each root module's test file
instead lives in its own `tests/` subdirectory
(`terraform/envs/network/tests/network.tftest.hcl`,
`terraform/envs/eks/tests/eks.tftest.hcl`) - matching Terraform's own
convention, and matching how the already-merged `terraform/tests/
toolchain.tftest.hcl` already works for the root module. Neither existing
file is moved or renamed by this change.

### VPC/EKS wiring choices made empirically, not guessed

`terraform-aws-modules/vpc` 6.7.2 has no direct `enable_s3_endpoint`-style
flag (verified against its real, downloaded source, not assumed from
older-version documentation) - VPC endpoints are deferred, not guessed at.
`terraform/envs/eks/` consumes `terraform/envs/network/`'s VPC/subnet
values as **explicit input variables**, not a `data "terraform_remote_state"`
lookup - that mechanism needs a real backend to exist first, out of scope
for this offline-only pass; wiring the two root modules together via
remote state is deferred to a later, separately authorized phase.
`mock_provider "aws"`'s low-fidelity default computed values required
explicit `override_data` blocks for the EKS module's own internal
`aws_partition`/`aws_caller_identity`/`aws_iam_policy_document` data
sources (an invalid-shaped fake ARN/JSON otherwise breaks the module's own
IAM role construction before any test assertion runs) - all overrides use
non-account-shaped placeholder values (e.g. the AWS-reserved literal
`"aws"` account-id keyword), never a 12-digit-shaped fake account id.

## Alternatives Considered

- **A manually-maintained root-module list**: rejected - exactly the
  "adding a root cannot silently bypass validation" failure mode this
  phase was explicitly asked to avoid.
- **Removing the resource-block ban entirely**: rejected - the root
  `terraform/` module (2.7.1's own toolchain smoke test) should stay
  permanently resource-free; scoping the ban rather than removing it
  preserves that guarantee.
- **A shared `terraform/tests/` directory for every root module's tests**:
  rejected once Terraform's own default test-directory resolution was
  checked directly - would silently run every root's tests against every
  other root.
- **`data "terraform_remote_state"` to wire `envs/network` into
  `envs/eks`**: deferred, not rejected - legitimate once a real backend
  exists, but unverifiable offline in this phase.

## Consequences

### Positive

- Adding a new `terraform/envs/<name>/` root module is now enforced
  automatically, with no tooling change and no registration step to
  forget - verified by dedicated regression fixtures.
- Real (never-applied) infrastructure-as-code can now exist in this
  repository without weakening any of the other offline-only guarantees.

### Negative

- The resource-ban/backend/lock-file exceptions are now three separate,
  narrowly-scoped carve-outs in `check-terraform-offline.sh`/
  `check-forbidden-terms.sh` rather than one simple rule each - each is
  documented and regression-tested individually, accepted as the cost of
  precision over a blanket rule.
- `envs/eks`'s explicit-variable coupling to `envs/network` (rather than
  remote state) will need to change once a real backend exists - a known,
  deferred piece of follow-up work, not a permanent design.

## Security and Cost Implications

Zero cost, zero AWS contact - re-verified this phase via the same
`AWS_SHARED_CREDENTIALS_FILE=/dev/null`/`AWS_CONFIG_FILE=/dev/null`/
`AWS_EC2_METADATA_DISABLED=true` proof already established in ADR-0011,
now passing across all four discovered root modules. No region, CIDR,
availability zone, node instance type, or Access Entry principal defaults
to any real/production value anywhere in this phase's code - each is an
explicit, no-default variable per `docs/adr/0011-terraform-foundation.md`'s
"no invented production default" principle, restated in
`.local/evidence/phase-2.7.2-network-eks-iac-plan.md` S3.

## Validation Method

`make terraform-validate-offline` (fmt/init `-backend=false`/validate/test
across every discovered root module) and `make check-terraform-offline`/
`make check-terraform-offline-regression` (31 accept/reject fixtures,
including the decisive "brand-new, previously unknown root is still
discovered and enforced" case) and `make check-forbidden-terms-regression`
(45 fixtures, including three new nested-lock-file-path cases) - all
passing offline, with the zero-AWS-contact proof re-run across all four
root modules.
