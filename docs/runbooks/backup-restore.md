# Runbook: Backup and restore on lab-multicluster

**Phase 6.2a–6.2b. Local kind labs only. `ACTUAL COST: USD 0`.**

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

## Restore drills (destructive)

Each drill deletes one member's cluster, rebuilds it from Git plus its
newest backup, verifies the result by SHA-256 and prints the RTO. Values
are never printed.

```bash
make backup-drill-spoke SPOKE=uat CONFIRM=yes
```

**Spoke drill.** It rebuilds in this order:

1. cluster;
2. registration;
3. ESO and metrics-server;
4. Velero, with the same key;
5. restore of Secrets, ConfigMaps, Roles and RoleBindings;
6. a refresh of Argo CD's cluster cache;
7. observability.

The order matters:
- The restore runs before `mc-up` or the observability install could
  generate a new source value or credential.
- The cache refresh, which writes an annotation on the hub's
  `spoke-<env>` Secret, makes Argo CD learn ESO's kinds. Without it the
  Application shows a ComparisonError on the ExternalSecret.

Measured RTO: 556 s.

```bash
make backup-drill-hub CONFIRM=yes
```

**Hub drill.** It needs `gh` acting as the repository owner, for example
`GH_TOKEN` pinned to that account, as `make mc-up` does. The bootstrap
re-checks the deploy key on GitHub, and the drill checks this before
deleting anything.

It rebuilds in this order:

1. cluster;
2. Argo CD;
3. Velero;
4. restore of `argocd` and `monitoring`;
5. observability;
6. bootstrap.

Argo CD reconnects with the restored cluster Secrets while their 24 h
tokens are valid. With expired tokens, re-register the spokes with
`make mc-up`. The rebuilt Loki starts empty.

Measured RTO: 350 s.

## Restore a member by hand

These are the same steps the drills run:

1. Rebuild the member.
   - **For a spoke:** in this order: cluster, `spoke-register`, ESO,
     metrics-server. Do not run `make mc-up` before the restore: it would
     ask for a new source value.
   - **For the hub:** the cluster and Argo CD.
2. `make backup-install LAB_CLUSTER=<member>`. It gets the same key back
   from the store and sees the old backups.
3. Create a Restore of the newest backup for that member's namespaces.
   - Use `existingResourcePolicy: none`.
   - Include `secrets`, `configmaps`, `roles.rbac.authorization.k8s.io`
     and `rolebindings.rbac.authorization.k8s.io`.
4. Finish the rebuild.
   - **For a spoke:** annotate the hub's `spoke-<env>` Secret to refresh
     Argo CD's cache, then run `make obs-install LAB_CLUSTER=<env>`.
   - **For the hub:** run `make obs-install LAB_CLUSTER=hub`, then the hub
     bootstrap.
5. Re-run the status targets.

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
