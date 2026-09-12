# ADR-0014: EKS Application Generation and Identity Boundary (Phase 3.3.4–3.3.5)

**Status:** Accepted
**Date:** 2026-09-12

## Context

Phase 3.3.1–3.3.3 built and offline-validated a dual-provider
(`kubernetes`|`aws`) secret contract in `charts/standard-workload`, plus the
matching `values-staging-aws.yaml`/`values-production-aws.yaml` overlays and
their cross-validation against `terraform/envs/identity`'s own declared
identity. Phase 3.3.4a connected those overlays to Argo CD declaratively: a
`profile` value (`local-kind`|`aws-eks`) on the shared `gitops/bootstrap`
chart, gating which environment list `templates/applicationset.yaml`'s
generator ranges over - never both at once, any other value failing the
render closed.

None of that, by itself, answers the question this ADR is about: **how would
an operator ever safely point this project's tooling at a real EKS cluster,
without ever confusing it for - or falling back to - the local `kind` lab?**
Every mechanism in this repository up to this point (`check_cluster_identity()`,
`pkubectl`, `phelm`, `PROJECT_KUBECONFIG`) is intentionally, permanently
specific to the one `kind` cluster this project runs locally. This phase adds
the missing identity boundary for a second, future, real cluster - as a
**separate, parallel** mechanism, never a modification of the first.

**`DESIGNED` / `STATICALLY VALIDATED` only - `NOT DEPLOYED`, `NOT VALIDATED
AGAINST AWS`. `ACTUAL COST: USD 0`.** No EKS cluster exists. No AWS account
is consulted by anything in this phase. `check_eks_cluster_identity()` has
never been run against a real cluster - every test exercising it uses a fake
`kubectl` script or a synthetic, credential-free kubeconfig file.

## Decision

### Two profiles, one default

`local-kind` remains the default for every existing entry point
(`lab/gitops/bootstrap.sh`, `gitops/bootstrap`'s own `PROFILE`-less
invocation) - every command that worked before this phase produces
byte-for-byte identical output after it (verified: `lab/gitops/bootstrap.sh`'s
full stdout, diffed pre/post-change, is identical for the default path).
`aws-eks` must be selected explicitly (`PROFILE=aws-eks`); an unrecognized
value fails closed immediately, both in the chart's `templates/
applicationset.yaml` (Helm's own `fail`) and in `lab/gitops/bootstrap.sh`.

### Identity boundary: `check_eks_cluster_identity()`, not a modified `check_cluster_identity()`

`scripts/lab/_lib.sh` gains a second, independent function,
`check_eks_cluster_identity()` - `check_cluster_identity()` (the kind check)
is untouched, in both its code and its own tests. The new function differs
from the old one in a way that matters: `check_cluster_identity()` reads
fixed `PROJECT_*` globals, because exactly one kind cluster exists in this
project and always will; `check_eks_cluster_identity()` takes every fact -
kubeconfig path, expected context, cluster name, region, endpoint, Git
revision, repo URL - as an **explicit, required argument**. A future EKS
cluster's identity is precisely the kind of fact this project's own
governance model (every prior phase's authorization message) requires as a
runtime parameter, never a value invented or defaulted in Git.

Verified structurally (`grep`, not by argument): the function's own body
contains zero mutating `kubectl` verbs (`apply`/`delete`/`patch`/`create`) -
every call is `config current-context`, `config view -o jsonpath=...`, or
`get --raw /healthz`, the last bounded by `--request-timeout=5s` so a
preflight against an unreachable endpoint fails within seconds rather than
hanging. It never invokes the `aws` CLI - a dedicated offline test
(`tests/lab/test-eks-identity-offline.sh`) proves this by placing a fake
`aws` binary first on `PATH` that logs any invocation and exits non-zero,
then asserting that log stays empty across the full positive and negative
matrix.

### Why not the AWS CLI in the static preflight

`aws eks describe-cluster`/`update-kubeconfig` and `aws sts get-caller-
identity` all require real AWS credentials and contact a real AWS endpoint -
exactly what this phase, and every phase of this project to date, is
constitutionally unable to do (no AWS account exists; the user's budget is
USD 0). The identity check instead validates everything derivable from
**explicit parameters plus a plain Kubernetes API read**: the region's static
shape (identical criterion to `terraform/envs/identity`'s own `aws_region`
variable), the endpoint's structural shape (`<id>.<region>.eks.amazonaws.com`
or the newer `.api.aws` IPv6 form - verified against AWS's own current
documentation, re-verified 2026-09-12, not assumed), and a cross-check that
the declared region is the one actually embedded in the declared endpoint.
Whether that endpoint is real - and whether it belongs to the AWS account the
operator thinks it does - is exactly the kind of fact only a future, real,
separately authorized operation against a live account can establish; this
static check cannot and does not claim to establish it. If a real EKS
cluster's kubeconfig ever uses an AWS exec-credential plugin
(`aws eks get-token`/`aws-iam-authenticator`), a real `kubectl` invocation
against it would trigger that plugin - this ADR does not claim otherwise -
but that first real invocation is out of scope for this phase by design,
deferred to `docs/runbooks/eks-bootstrap-order.md`'s own, separately
authorized steps.

### Pod Identity, not access keys or IRSA

Unchanged from Phase 3.2/3.3.1 - restated here because this ADR is the
canonical place a future reader would look for the reasoning. EKS Pod
Identity requires no per-pod IAM role annotation, no OIDC provider trust
policy to maintain, and (per External Secrets Operator's own documentation)
no `auth` block on the `SecretStore` at all. Static access keys are
structurally impossible in this design - `values.schema.json`'s `aws`
provider branch does not declare `accessKeyID`/`secretAccessKey`/
`sessionToken` as schema properties for either provider, so
`additionalProperties: false` rejects them outright.

### Ownership boundary

| Resource | Owner |
|---|---|
| VPC/EKS/nodes, Access Entries, Pod Identity Agent, IAM/KMS/Secrets metadata, Pod Identity Associations | Terraform |
| Isolated project kubeconfig | Bootstrap/operator |
| Argo CD release/CRDs, ESO releases/CRDs, repo credential, root Application | Bootstrap (imperative, `lab/*/install.sh`-style) |
| AppProject/ApplicationSet, generated Applications | Argo CD GitOps |
| `SecretStore`/`ExternalSecret`/workload | Applications (chart-rendered) |
| Secret payload | Out-of-band operation, never Terraform, never Git |
| Kubernetes Secret destination | ESO |

No ownership conflict or circular dependency was found (re-confirmed from
the Phase 3.3.4 addendum): a Pod Identity Association can be created before
the Kubernetes ServiceAccount it targets exists - AWS does not require the
reverse order.

### Limitations of offline validation

`tests/lab/test-eks-identity-offline.sh` proves `check_eks_cluster_identity()`'s
own logic is internally consistent - given a set of inputs and a scripted
`kubectl` response, it reaches the correct `EKS_IDENTITY_CASE` every time.
It cannot, and does not claim to, prove that a *real* EKS cluster's kubeconfig
would produce those same responses, that a real endpoint is reachable, or
that the region/account it belongs to is the one an operator intends. Those
are exactly the class of fact this ADR defers to a future, real, separately
authorized bootstrap run.

## Alternatives Considered

- **Extending `check_cluster_identity()` in place** (an `if profile==...`
  branch inside the same function) - rejected: it would make the kind-only
  code path harder to reason about for zero benefit, and risks a future edit
  to the EKS branch silently affecting the kind branch's own PROJECT_*
  constant reads.
- **Using the AWS CLI for the static preflight** - rejected per the Context/
  Decision sections above: this project has no AWS credentials to use, by
  design, for the entire duration of Phase 3.
- **A cluster-generator-based `ApplicationSet` (multicluster registration)**
  - rejected in the Phase 3.3.4 addendum and reaffirmed here: no real second
  cluster exists to register, and Phase 3's own scope explicitly excludes
  multicluster.

## Consequences

- A future, separately authorized phase can implement the actual `aws-eks`
  mutation path (applying a real root Application against a real EKS
  cluster) by extending `lab/gitops/bootstrap.sh`'s `aws-eks)` branch past
  its current, deliberate stopping point (identity preflight + fingerprint,
  no apply) - `docs/runbooks/eks-bootstrap-order.md` documents that future
  order without executing any of it.
- `pkubectl`/`phelm` remain hardcoded to `$PROJECT_KUBECONFIG` (the kind
  cluster) - the `aws-eks` branch deliberately does not call
  `argocd_release_exists`/`require_helm` (which would silently check the
  *kind* cluster's own Argo CD, not a nonexistent EKS one). Making those
  helpers kubeconfig-parameterized is flagged as a residual, not yet
  authorized piece of work.

## Security and Cost Implications

Zero cost, zero AWS contact - `check_eks_cluster_identity()` never
invokes the `aws` CLI or any AWS SDK, and every test exercising it
(`tests/lab/test-eks-identity-offline.sh`) uses a fake `kubectl` and a
fake `aws` that fails immediately if invoked, against synthetic,
credential-free kubeconfig fixtures generated under `mktemp -d` and
removed via `trap ... EXIT INT TERM`. No certificate, token, user, or
exec-credential content is ever read into a variable this project
prints or stores - `eks_identity_fingerprint()` emits only
profile/context/cluster/region/endpoint/revision/repoURL, mirroring the
same non-secret-fingerprint discipline as Phase 2.6.3a's
`gitops_root_app_desired_fingerprint`. If a real EKS cluster's
kubeconfig ever used an AWS exec-credential plugin, invoking `kubectl`
against it for real would trigger that plugin and could incur AWS API
calls - out of scope for this phase, deferred to
`docs/runbooks/eks-bootstrap-order.md`. **`ACTUAL COST: USD 0`** - no
EKS cluster, no Terraform apply, and no AWS account exist for this
phase to contact.

## Validation Method

`sh tests/lab/test-eks-identity-offline.sh` / `make
lab-test-eks-identity-offline` (25 positive/negative/structural cases,
fully offline); `make validate` (now includes the target above);
`lab/gitops/bootstrap.sh`'s default (`local-kind`) path re-verified
byte-identical to its pre-Phase-3.3.4b output; `PROFILE=aws-eks` and
`PROFILE=<unrecognized>` both re-verified to fail closed before any
`kubectl apply`/`helm install`-equivalent call. No `terraform plan`/
`apply` against real AWS, no real backend, no AWS credential, no real
account ID/ARN/endpoint/cluster name anywhere in this phase's code.
