# ADR-0022: Backup and restore of the state outside Git

**Status:** Accepted
**Date:** 2026-11-18

## Context

The roadmap (6.2) asks for cluster-resource and volume backup to object
storage, and a scripted restore drill with recorded evidence. Measured on
2026-11-18 on lab-multicluster (hub, dev, uat):

- **No PersistentVolumeClaims.** Prometheus, Loki and Grafana use
  `emptyDir` by design (ADR-0021).
- **Desired state is in Git.** Argo CD rebuilds the workloads; `make
  mc-up` and `make obs-install` rebuild the platform add-ons.
- **The state that is not in Git is a handful of Secrets.**
  - On the hub: the Argo CD repository Secret (deploy key), the cluster
    Secrets of each spoke, the Argo CD admin and Redis Secrets, and the
    observability credentials.
  - On each spoke: the ESO source value (`eso-source-<env>`) and the
    spoke's credential for metrics and logs.
- **What can be regenerated.** The credentials can, but every other
  member must then learn them. The ESO source value cannot: it is the
  lab's stand-in for an application's secrets, and a rebuilt spoke would
  get a new one.

## Decision

- **Velero backs up only the state that is not in Git.**
  - Velero 1.18.2 (`vmware-tanzu/velero` chart 12.2.3) runs on every
    member, with the AWS plugin v1.14.4 for S3.
  - Each backup holds Secrets, ConfigMaps, PersistentVolumeClaims and
    PersistentVolumes of that member's platform namespaces:
    - hub: `argocd`, `monitoring`;
    - spoke: `eso-source-<env>`, `monitoring`, `logging`.
  - A label selector excludes what Helm owns (release records and chart
    objects), because the install scripts recreate those and restoring
    them would fight Helm.
  - Workloads are never restored from backup: Argo CD rebuilds them from
    Git.
- **Lab object store: Versity S3 Gateway (`versitygw` v1.10.0,
  Apache-2.0).**
  - One container on the kind docker network. Only its S3 port (7070) is
    reachable, only from that network; the admin API listens on loopback.
  - Data, object metadata (a sidecar directory, because the macOS bind
    mount has no extended attributes) and its IAM file live under
    `.local/backups/` (gitignored, mode 700). They outlive every cluster
    and the container.
  - The root credential is generated at first start into a mode-600 env
    file. It is used only by the admin CLI inside the container, and
    never on a command line.
- **One bucket and one key per member.**
  - User `velero-<cluster>` owns bucket `velero-<cluster>`. A user can
    neither create buckets nor read another user's bucket (403, tested).
  - The key lives in the store's IAM file, which the gateway reads on
    every request (cache disabled), so adding or removing a key needs no
    restart.
  - A rebuilt member gets its old key back and can read its old backups.
- **Schedule.** Every 6 hours, TTL 72 h. `make backup-now` takes an
  on-demand backup with the same spec.
- **No volume layer yet.** No node agent, no volume snapshot location, no
  CRD-upgrade Job: CRDs come from the chart's `crds/` directory. 6.3
  turns the node agent on with its data store.
- **Least privilege.**
  - The chart's RBAC is off; by default it binds `cluster-admin` and
    grants a wildcard Role.
  - Velero gets a ClusterRole for exactly the kinds a backup holds (read
    and restore), namespaces (create, for restores), events, and
    read-only pods, CustomResourceDefinitions and ClusterRoleBindings. A
    backup or restore fails without these last three, as measured.
  - It also gets a Role in its own namespace that names its resources one
    by one, plus leases and reading its own Deployment.
  - Pods are restricted, and a NetworkPolicy admits only `monitoring` on
    the metrics port.
- **Backup health in the hub.** Each Velero is scraped (by the spoke
  agents, and on the hub by the hub Prometheus). The rules in
  `platform/observability/rules/backup.rules.yml` cover:
  - a failed last backup;
  - no success in 13 h;
  - no success at all for 13 h while Velero is up;
  - the backup storage unavailable for 10 min;
  - Velero down for 10 min.

  Every alert is unit-tested under the rules contract of ADR-0021.
- **Restore without touching anything live.** `make
  backup-restore-check` restores the newest backup into throwaway
  namespaces. It compares every Secret by SHA-256 and removes those
  namespaces.
- **The destructive drills are 6.2b.** Losing a spoke and losing the hub
  are separate drills that need their own authorization.

## Alternatives Considered

- **SeaweedFS.** Rejected after testing it. It denies S3 requests when
  no identity exists, but its S3 gRPC port, which can reconfigure
  identities, binds with the S3 port and cannot be kept on loopback. Its
  filer IAM service also warns that it is unauthenticated. Closing that
  would need mTLS just for the lab.
- **moto, the Terraform emulator.** Rejected: it keeps data in memory,
  so a restart loses every backup.
- **MinIO and Garage.** Rejected: AGPL, and MinIO's community images are
  no longer published.
- **An etcd snapshot.** Rejected: all-or-nothing, tied to one control
  plane, and not available on EKS.
- **Restoring workloads from backup.** Rejected: it would race Argo CD
  and hide drift from Git.
- **The chart's default RBAC (`cluster-admin`).** Rejected; the narrow
  set above works, as measured.

## Consequences

- A member can be rebuilt from Git plus its newest backup without
  rotating credentials or losing the ESO source value. 6.2b proves it.
- Velero's CRDs stay on a member after `make backup-uninstall`, because
  Helm never deletes `crds/`.
- The store is one more container to keep running for the lab
  (`make backup-store-up`). With the store down, backups fail and
  `VeleroBackupStorageUnavailable` fires.
- Prometheus and Loki data are not backed up; that loss is accepted
  (ADR-0021).

## Security and Cost Implications

- **Backups hold Secrets in clear text.** Velero does not encrypt
  resource data (TAD R-18). Lab mitigations:
  - the store is reachable only from the kind network;
  - `.local/backups` is mode 700 and gitignored;
  - one key per member, confined to its own bucket.

  On AWS: S3 with SSE-KMS, a bucket policy per member role, and Object
  Lock, decided at 6.4.
- **Plain HTTP** between members and the store: LAB-ONLY.
- **Cost:** USD 0 (local only).

## Validation Method

- **6.2a, offline:**
  - `make backup-render`, for hub, dev, uat and prod:
    - exact object set;
    - pinned images;
    - no Secret, node agent, Job or snapshot location;
    - the exact ClusterRole rules;
    - no wildcard, no `cluster-admin`;
    - restricted pods;
    - its own bucket on the store, path-style, no checksums;
    - schedule, TTL, namespaces, kinds and the Helm exclusion;
    - the NetworkPolicy.
  - `make check-observability`: 5 backup alerts unit-tested, plus 2
    regression mutations.
- **6.2a, live on lab-multicluster (2026-11-18):**
  - The store exposes only port 7070 to the kind network.
  - Velero is installed on hub, dev and uat, each with its
    BackupStorageLocation Available.
  - On-demand backups completed: the hub holds 9 Secrets and 3
    ConfigMaps; each spoke holds its 3 Secrets.
  - `make backup-restore-check` restored all 15 Secrets identical (by
    SHA-256) into throwaway namespaces.
  - The hub scrapes Velero on every member, and the 5 rules are healthy.
  - Fire test: with the store stopped, `VeleroBackupStorageUnavailable`
    reached Alertmanager for all three members after about 13 min.
    Restarted, the locations returned to Available, old backups still
    restored identical, new backups completed, and the alerts resolved
    after 81 s.
  - Memory: Velero 42–81 Mi per member, the store 17 MiB.
- **6.2b:** recorded here when the drills run.
