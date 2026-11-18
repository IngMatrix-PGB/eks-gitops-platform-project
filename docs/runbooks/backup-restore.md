# Runbook: Backup and restore on lab-multicluster

**Phase 6.2a. Local kind labs only. `ACTUAL COST: USD 0`.**

[ADR-0022](../adr/0022-backup-and-restore.md) sets the rule: Velero backs
up only the state that is not in Git, and Argo CD rebuilds everything
else from Git.

What each member's backup holds:

| Member | Namespaces | What matters in them |
|---|---|---|
| hub | `argocd`, `monitoring` | the repository Secret (deploy key), the spokes' cluster Secrets, Argo CD's admin and Redis Secrets, the observability credentials |
| dev, uat, prod | `eso-source-<env>`, `monitoring`, `logging` | the ESO source value, the spoke's credential for metrics and logs |

Helm's release records and chart objects are excluded: the install
scripts recreate them.

## Prerequisites

- lab-multicluster up (`make mc-up`).
- `make tools-install` and `make backup-chart-fetch`.

## Start the store, then install Velero

```bash
make backup-store-up
```

```bash
make backup-install LAB_CLUSTER=hub
```

```bash
make backup-install LAB_CLUSTER=dev
```

```bash
make backup-install LAB_CLUSTER=uat
```

**The store.** It is a Versity S3 Gateway container on the kind
network. Its data, object metadata and keys live in `.local/backups/`
(mode 700, gitignored). Removing the container (`make
backup-store-down`) keeps all of them.

**The install.** For each member it creates (or keeps) the S3 user
`velero-<cluster>` and the bucket `velero-<cluster>` it owns. It then
installs Velero, with a schedule every 6 hours and a 72-hour TTL.

## Check

```bash
make backup-status LAB_CLUSTER=dev
```

This shows the release, Velero Available, the BackupStorageLocation
Available, and the newest completed backup younger than 13 hours.

```bash
make backup-now LAB_CLUSTER=dev
```

This takes an on-demand backup with the schedule's spec.

```bash
make backup-restore-check LAB_CLUSTER=dev
```

This restores the newest backup into throwaway `bkcheck-*` namespaces,
compares every Secret with the live one by SHA-256, and deletes those
namespaces. Nothing live is touched.

In the hub, Grafana and Alertmanager show the backup alerts:

- `VeleroBackupFailed`
- `VeleroBackupStale`
- `VeleroNoSuccessfulBackup`
- `VeleroBackupStorageUnavailable`
- `VeleroDown`

## Restore a member's state

The scripted drills of 6.2b automate this; the steps are the same:

1. Rebuild the member:
   - for a spoke: `make mc-up SPOKES=<env>`, without a source value file;
   - for the hub: recreate the hub and its Argo CD.
2. `make backup-install LAB_CLUSTER=<member>`. It gets the same key back
   from the store and sees the old backups.
3. Create a Restore of the newest backup for that member's namespaces.
   - Use `existingResourcePolicy: none`, so it never overwrites a live
     object.
   - Include `secrets` and `configmaps`.
4. Let ESO and Argo CD converge, then re-run the member's status targets.

## Remove

```bash
make backup-uninstall LAB_CLUSTER=dev
```

This removes the release and the credential Secret. It keeps Velero's
CRDs, which Helm never deletes, and keeps the member's bucket, backups
and key in the store.

## Security notes

- **Backups hold Secrets in clear text.** Keep `.local/backups` private.
  It is never in Git (TAD R-18).
- **One key per member, confined to its own bucket.** Another member's
  key gets 403.
- **The store's root credential** is in `.local/backups/config/` (mode
  600). It is used only by the admin CLI inside the container.
- **LAB-ONLY: plain HTTP to the store.** The AWS design (SSE-KMS, bucket
  policy per role, Object Lock) is decided at 6.4.
