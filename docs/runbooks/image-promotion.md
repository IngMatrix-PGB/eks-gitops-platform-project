# Runbook: Promoting the first-party images dev → uat → prod

**Phase 5.1c. Tooling implemented (5.1c-1); the first promotions wait
for a signed image published from `main` (Phase 5.1b) and a public GHCR
package. `ACTUAL COST: USD 0`.**

See [ADR-0017](../adr/0017-image-supply-chain.md) for the decisions and
[image-publish.md](image-publish.md) for how a digest is produced.

## Rules

- **Phase 6.3c: one flow per app.** `APP=smoke` (the default) or
  `APP=notes`. Each app has its own overlays, ledger
  (`gitops/promotions/<app>.tsv`) and image repository; the rules below
  apply to each one separately. notes has one overlay per environment,
  `charts/standard-workload/values-notes-<env>.yaml` (no `-aws` copy:
  notes is lab-only until 6.4).

- Every environment's image lives in its two overlays
  (`charts/standard-workload/values-<env>.yaml` and
  `values-<env>-aws.yaml`), which always hold the same reference.
- **dev** takes a digest published and signed from `main`; **uat** takes
  dev's current image; **prod** takes uat's. Nothing else is accepted.
- Every promotion appends one row to `gitops/promotions/smoke.tsv`.
  Rows are never edited or removed.
- The promotion pull request is the human review gate. It is opened by
  a person, never by a workflow.

## Promote

1. Start from an up-to-date `main` on a new branch.
2. Run, for the environment you promote:

   ```bash
   make promote ENV=dev DIGEST=sha256:<digest from the image workflow's job summary>
   ```

   ```bash
   make promote ENV=uat
   ```

   ```bash
   make promote ENV=prod
   ```

   For notes, add `APP=notes`. Its first promotion into an environment
   needs that environment's overlay to exist with its configuration; see
   "Enabling notes in an environment" below.

   The script verifies the image first (`make image-verify`: keyless
   signature by the main image workflow and a CycloneDX SBOM attestation
   per platform). An image that does not verify is not promoted, and
   nothing is changed.
3. Review `git diff`. Exactly three files change: the environment's two
   overlays and one new ledger row.
4. Commit, push, and open the PR. CI runs:
   - `validate` → `make check-promotion` (offline): per-overlay pinned
     images, local/aws agreement, promotion order, append-only ledger;
   - `promotion` → `make promotion-verify` (online): every overlay image
     of our repository verifies against the exact signer identity.
5. Merge after review. Argo CD rolls the environment out. Run the lab
   regression for that environment before promoting the next one:
   `make gitops-test`, `make workload-test-resilience` (prod), and
   `make workload-test-autoscaling` (prod).

## Enabling notes in an environment (Phase 6.3c)

One promotion pull request per environment moves smoke and notes
together:

1. The database credentials exist on that spoke:
   `make eso-provision-db-secret ENV=<env>`
   ([reference-app-data.md](reference-app-data.md)).
2. Add `charts/postgres-lab/values-<env>.yaml` and
   `charts/standard-workload/values-notes-<env>.yaml` (configuration
   only; copy dev's and change the environment names).
3. `make promote APP=notes ENV=<env> ...` adds the notes image block and
   a row to `gitops/promotions/notes.tsv`; `make promote ENV=<env> ...`
   does the same for smoke.
4. In smoke's `values-<env>.yaml`, set `extraEnv.NOTES_URL` and the
   egress rule to notes.
5. List `<env>` under `notes` and `postgres` in
   `gitops/bootstrap/values.yaml`. `check-promotion` fails if notes is
   listed without a promoted overlay, without postgres, or the other
   way round.

## Roll back

A rollback is a promotion of an earlier digest the environment already
had. For dev, `make promote ENV=dev DIGEST=<earlier digest>`. For uat
and prod, roll back the source environment first, then promote again.
The ledger keeps both rows; that is the audit trail.

## Lab tests and the workload image

`apps/smoke` is distroless and has no shell. The lab tests send traffic
from the pinned test client image (`scripts/workload/_lib.sh`) and probe
the workload's network from an ephemeral container in the workload pod
(`kubectl debug --profile=restricted`), so they never depend on a shell
in the workload image. `check-supply-chain` keeps it that way.
