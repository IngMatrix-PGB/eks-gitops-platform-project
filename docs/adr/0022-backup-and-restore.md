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
  - Each backup holds Secrets, ConfigMaps, Roles, RoleBindings,
    PersistentVolumeClaims and PersistentVolumes of that member's platform
    namespaces. Roles and RoleBindings were added by the 6.2b drill: the
    ESO source Secret's reader RBAC is created by the same imperative
    script as the Secret, so it is outside Git too:
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
  - Roles and RoleBindings are among the kinds it restores. Kubernetes
    refuses to create one that would grant more than Velero itself holds,
    so restoring RBAC cannot escalate.
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
- **Two scripted, destructive drills (6.2b).** Each needs `CONFIRM=yes`.
  - **`make backup-drill-spoke SPOKE=<env>`.** It deletes the spoke and
    rebuilds it in this order:
    1. cluster;
    2. registration;
    3. ESO and metrics-server;
    4. Velero, with the same store key;
    5. restore of the backup;
    6. a refresh of Argo CD's cluster cache;
    7. observability.

    The restore comes before anything could generate a new source value
    or credential. The cache refresh is needed because the spoke was
    registered before ESO's CRDs existed. With it, the SecretStore is
    created only after its source and RBAC exist.
  - **`make backup-drill-hub`.** It deletes the hub and rebuilds it in this
    order:
    1. cluster;
    2. Argo CD;
    3. Velero;
    4. restore of `argocd` and `monitoring`;
    5. observability;
    6. bootstrap.

    It needs `gh` acting as the repository owner, as `make mc-up` does,
    because the bootstrap re-checks the deploy key on GitHub. It checks
    this before deleting anything.
  - Both verify by SHA-256 and print the RTO.

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
- **6.2b, live on lab-multicluster (2026-11-18):**
  - **Spoke drill (uat), RTO 556 s.**
    - Times per step:

      | Step | Time |
      |---|---|
      | Cluster | 37 s |
      | Registration | 3 s |
      | ESO | 120 s |
      | metrics-server | 28 s |
      | Velero, up to the backup being visible | 82 s |
      | Restore | 4 s |
      | Observability | 57 s |
      | Argo CD convergence and workload Ready | 223 s |

    - The ESO source Secret and the workload's ESO-built Secret were
      identical by SHA-256.
    - The hub's user list was unchanged, so the spoke got no new
      credential.
    - dev kept the same pods.
    - Metrics and logs flowed with the restored credential, and backups
      with the same key.
    - A later `make mc-up SPOKES=uat` left the source Secret as restored.
  - **Hub drill, RTO 350 s.**
    - Times per step:

      | Step | Time |
      |---|---|
      | Cluster | 38 s |
      | Argo CD | 45 s |
      | Velero | 85 s |
      | Restore | 4 s |
      | Observability | 149 s |
      | Bootstrap | 6 s |
      | Convergence | 20 s |

    - The repository Secret and the hub's user list were identical.
    - Both spokes' cluster Secrets were identical: Argo CD reconnected
      without re-registration, with the 24 h tokens still valid.
    - The spokes' pods were unchanged, and nothing was reinstalled on a
      spoke.
    - Both agents sent to the rebuilt hub with nothing refused, and the
      rebuilt Loki gateway accepted both unchanged log credentials.
    - Hub metrics from all three clusters; rules healthy.
    - The rebuilt Loki started empty (`emptyDir`, as accepted in
      ADR-0021).
  - **Found by the drills and fixed before they passed:**
    - The source Secret's reader RBAC was not in the backup; the
      SecretStore stayed InvalidProviderConfig until it was recreated by
      hand in that run.
    - Argo CD's cluster cache missed ESO's schema after
      re-registration, which gave a ComparisonError.
    - Two credential probes started in the same second could pick the
      same local port; a Loki probe then reached Prometheus and got 404.
      The probe now uses a port per call and requires a 401 from the
      intended service first.
    - The hub bootstrap needs the GitHub owner account, which the hub
      drill now checks first.
    - A hub rebuild leaves Loki empty: `obs-status` has
      `EXPECT_LOG_CLUSTERS`, and the drill checks that Loki accepts each
      credential instead.
    - The failed runs were not counted; each drill was rerun from
      scratch.
