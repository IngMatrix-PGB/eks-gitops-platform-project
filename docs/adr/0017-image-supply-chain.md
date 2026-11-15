# ADR-0017: Image supply chain and promotion

**Status:** Accepted
**Date:** 2026-11-13

Implemented: Phase 5.1a. Proposed: 5.1b and 5.1c (below).

## Context

The platform deployed only an upstream image (`podinfo`), pinned by
digest. Nothing in the repository was built here, so nothing proved that
an image this project produces is tested, scanned, described and
traceable before it reaches an environment. The TAD roadmap (5.1) asks
for build, a vulnerability scan with a failing threshold, an SBOM, a
signature, a push to a registry, and promotion `dev` → `uat` → `prod`
as pull requests that change an immutable image reference.

Two repository facts constrain the design (read from the GitHub API,
unchanged by this ADR):

- **Actions policy:** only GitHub-owned actions are allowed, and every
  action must be pinned by commit SHA (ADR-0009).
- **Workflow token:** read-only by default, and workflows cannot create
  or approve pull requests.

## Decision

- **A first-party image:** `apps/smoke`, a minimal Go service (standard
  library only) that honors the standard-workload chart's contract: port
  9898, `/healthz`, `/readyz` turning 503 on SIGTERM, bounded graceful
  shutdown, non-root (UID 65532), read-only root filesystem. Phase 6.3
  grows it into the multi-language reference application.
- **Build:** a multi-stage Dockerfile. Both bases are pinned by digest.
  `go vet` and the unit tests run in the build stage, so no image exists
  for code whose tests fail. The runtime is distroless static `nonroot`.
- **Scanner and threshold:** Trivy. The build fails on any `HIGH` or
  `CRITICAL` vulnerability that has a fix, and on any `HIGH` or
  `CRITICAL` Dockerfile misconfiguration. Unfixed findings are printed
  but cannot fail the build. Accepted findings go in
  `apps/<app>/.trivyignore`, each with an expiry date and a
  justification; an expired entry fails `make validate`.
- **SBOM:** CycloneDX JSON from syft, uploaded as a workflow artifact.
- **Tools, not third-party actions:** trivy and syft are pinned with
  their checksums in `scripts/lab/tool-versions.txt` and installed by
  the same checksum-verified pipeline as kind, kubectl, helm and
  terraform. The workflow calls `make` targets a developer can run
  locally. The only actions are GitHub-owned and SHA-pinned.
- **Static guard:** `check-supply-chain` (in `make validate`) enforces
  SHA-pinned GitHub-owned actions, no write permission and no
  `pull_request_target`, digest-pinned bases, a numeric non-root final
  user, the scan threshold, dated `.trivyignore` entries, and Dependabot
  coverage (`docker` and `gomod` for each app).
- **Proposed next (5.1b, 5.1c):** push to GHCR from `main` only,
  keyless signing with cosign (GitHub OIDC) and the SBOM as an
  attestation; promotion as a local `make promote` that changes one
  digest per environment, a pull request opened by a person, and CI
  checks for promotion order and signature identity.

## Alternatives Considered

- **Rebuild podinfo.** Rejected: it proves nothing about code this
  project owns.
- **Third-party actions** (Trivy, cosign, syft, Docker build-push).
  Rejected for now: allowing them changes the repository's Actions
  policy and adds code that runs with the workflow token. The CLIs give
  the same result through a pipeline that already verifies checksums.
- **Grype instead of Trivy.** Equivalent for images. Trivy also scans
  the Dockerfile, so one tool covers both checks.
- **A bot that opens promotion pull requests.** Rejected: it needs a
  repository setting that lets workflows create pull requests, and it
  would let a workflow author its own promotion.

## Consequences

- Every change to the app, its Dockerfile, the image scripts or the
  pinned tools runs `.github/workflows/image.yml`: build, scan, SBOM.
- A base image with a fixable HIGH/CRITICAL vulnerability blocks the
  change until the digest is bumped. Dependabot proposes those bumps.
- The workload still runs podinfo. The switch happens by promotion in
  5.1c, after the image is signed and published.

## Security and Cost Implications

- 5.1a pushes and signs nothing. The image workflow has `contents: read`
  only, and `check-supply-chain` rejects any write permission.
- The image has no shell and no package manager, and runs as non-root.
- Cost: GitHub Actions minutes are free for a public repository; the
  tools are open source. USD 0.

## Validation Method

- `make image-all` locally and in CI: build with tests, non-root check,
  Trivy (vulnerabilities and misconfiguration), SBOM.
- `make check-supply-chain` and its mutation checks: a tag instead of a
  SHA, a third-party action, a write permission, an unpinned base, a
  root user, a lowered threshold, a non-failing scan, an expired or
  unjustified ignore entry, a missing Dependabot ecosystem.
- Functional mutations: a failing unit test stops the build; a Go
  toolchain with known stdlib CVEs (1.25.4) fails the scan.
