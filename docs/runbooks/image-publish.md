# Runbook: Publishing and verifying the first-party image

**Phase 5.1b. `DESIGNED`; first real run happens on the first push to
`main` that touches `apps/`, the image scripts, the pinned tools or
`.github/workflows/image.yml`. `ACTUAL COST: USD 0`** (GitHub Actions and
GHCR are free for a public repository; Sigstore's public instance is
free).

See [ADR-0017](../adr/0017-image-supply-chain.md) for the decisions.

## What the publish job does

On a push to `main`, after the PR-time job (build, scan, SBOM,
multi-platform build) passes, the `publish` job of `image.yml`:

1. pushes a `linux/amd64` + `linux/arm64` index to
   `ghcr.io/ingmatrix-pgb/eks-gitops-platform-smoke`, tag `sha-<12 hex>`
   (no `latest`; the digest is the reference);
2. re-scans every platform of the pushed digest (`make image-scan-remote`,
   same threshold);
3. signs the index keylessly and attests a CycloneDX SBOM to each
   platform manifest (`make image-sign`);
4. attaches SLSA build provenance (`actions/attest-build-provenance`);
5. verifies all of it against the exact signer identity
   (`make image-verify`);
6. writes `repo@sha256:...` to the job summary. That is the value
   Phase 5.1c promotes.

## First publish: one manual step

The first push creates the package as **private**, and the kind lab
must pull it without credentials (no image pull secret is ever added).

1. Open the run on `main`, confirm every step of `publish` passed, and
   copy the reference from the job summary.
2. On GitHub: your profile → **Packages** →
   `eks-gitops-platform-smoke` → **Package settings** →
   **Change visibility** → **Public**. Confirm the package shows this
   repository under "Repository source" (from the image's
   `org.opencontainers.image.source` label).
3. From a machine with no GHCR login, verify:

   ```bash
   make image-verify IMAGE=ghcr.io/ingmatrix-pgb/eks-gitops-platform-smoke@sha256:<digest>
   ```

   Expected: the index signature and one SBOM attestation per platform,
   all verified against
   `https://github.com/IngMatrix-PGB/eks-gitops-platform-project/.github/workflows/image.yml@refs/heads/main`.
4. Pull it in the lab with no credentials (kind on Apple silicon pulls
   the `linux/arm64` variant):

   ```bash
   docker pull ghcr.io/ingmatrix-pgb/eks-gitops-platform-smoke@sha256:<digest>
   ```

## If the publish job fails

- **Push denied:** the workflow token needs `packages: write` on the
  `publish` job only; check that the job ran on `main`.
- **Signing or verification failed (Sigstore outage, identity
  mismatch):** the job fails, and the digest it pushed is unsigned.
  Nothing promotes an unsigned digest (Phase 5.1c checks the signature),
  so re-run the job once the cause is fixed. Never verify with a regex
  identity.
- **Remote scan failed:** a fixable HIGH/CRITICAL appeared between the
  PR scan and the push (new advisory). Bump the base or Go version in a
  PR; the pushed digest stays unpromoted.

## Publishing from a laptop

Not part of the normal flow. `make image-publish` refuses to run outside
CI unless `IMAGE_PUBLISH_CONFIRM=yes` is set, and a laptop cannot
produce the trusted signature (keyless signing from a laptop would carry
your personal identity, which `make image-verify` rejects).
