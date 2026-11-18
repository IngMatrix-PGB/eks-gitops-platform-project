# ADR-0023: Reference application with a data store

**Status:** Accepted
**Date:** 2026-11-18

## Context

The roadmap (6.3) asks to grow `apps/smoke` into a small multi-language
application (two or three services) with one data store whose
credentials arrive through ESO, proving the standard chart across
languages. Measured on 2026-11-18:

- **One application.** `apps/smoke` is one Go service. It runs as one
  Application per spoke from `charts/standard-workload`, the stateless
  contract of ADR-0006.
- **Three lists of kinds.** What Argo CD may manage on a spoke lives in
  three places that must agree: the AppProject's
  `namespaceResourceWhitelist`, the spoke Role
  (`platform/spoke-access/role.yaml`, shared with EKS), and Argo CD's
  `resource.inclusions` for the spokes (`lab/argocd/values-lab.yaml`).
  None of them allowed a `StatefulSet`, a `PersistentVolumeClaim`, a `Job`
  or a `CronJob`.
- **No way to change Argo CD's values.** `make argocd-install` refuses,
  on purpose, any values change on an installed Argo CD, and no other
  path existed.

## Decision

- **Target shape.** The application grows into three components:
  - `smoke` (Go), the edge;
  - `notes` (Python), which owns the data;
  - `postgres`, the data store, from its own chart, with credentials
    through ESO.

  It is built in sub-phases 6.3a–6.3e, one pull request each.
- **6.3a — the platform contract for stateful components.**
  - The three places gain exactly four namespaced kinds, in lockstep:
    - `apps/StatefulSet`;
    - `/PersistentVolumeClaim`;
    - `batch/Job`;
    - `batch/CronJob` (for the data store's logical dumps).

    `Secret`, cluster-scoped kinds and wildcards stay excluded.
  - `check-spoke-access` now compares all three places, not two.
    `check-spoke-access-regression` rejects a kind missing from any one
    of them, an extra kind in the inclusions, and a Role granting
    Secrets.
  - Existing spokes pick up the new Role through
    `make mc-spoke-register`, which also rotates their 24 h token.
- **An explicit Argo CD values upgrade.** `make argocd-upgrade
  CONFIRM=yes` is the one path that applies a reviewed
  `lab/argocd/values-lab.yaml` change to a running Argo CD.
  - **Same pinned chart only.** A release that is not `deployed` is
    refused, and a release already at the values is a no-op.
  - **It shows the change before applying it:** each rendered object
    that changes, plus the line diff of ConfigMaps. It never prints
    Secret content.
  - **Same upgrade as install.** It upgrades with exactly install's
    arguments and description, so `make argocd-install` is a no-op
    afterwards. CRDs are kept.
  - **Automatic rollback.** If the live manifest does not match the
    offline render, it rolls back to the previous revision.
- **YAML is parsed with a pinned `yq`.** The render checks used PyYAML,
  which the system Python does not have; that left the result depending
  on the Python found first in `PATH`. `yq` v4.54.1 is pinned in
  `tool-versions.txt` with its published SHA-256. `backup-render` and
  `argocd-upgrade` now convert YAML to JSON with it.
- **Changed from the plan.** The ApplicationSet change to one Application
  per spoke and component moves to 6.3b, together with the second
  component. Without that component the matrix cannot be shown to
  generate the right Applications. Today it would be a refactor with
  nothing to prove.

## Alternatives Considered

- **Uninstall and reinstall Argo CD to change its values.** Rejected: it
  is disruptive, and the 6.2b hub drill already measured what rebuilding
  costs. An explicit, diffed, confirmed upgrade with rollback is the
  safer path.
- **Allowing every namespaced kind on spokes.** Rejected: a wildcard in
  the Role defeats R-05. The list stays explicit, and three checked
  places keep it honest.
- **Stateful kinds inside `standard-workload`.** Rejected: that chart is
  the stateless contract (ADR-0006). The data store gets its own chart in
  6.3b.

## Consequences

- Argo CD may now create StatefulSets, PVCs, Jobs and CronJobs in a
  spoke's environment namespace. Nothing renders one yet; 6.3b does.
- Any change to `lab/argocd/values-lab.yaml` reaches a running hub only
  through `make argocd-upgrade CONFIRM=yes`.
- Changing the spoke Role reaches running spokes through
  `make mc-spoke-register`, which also rotates their tokens.

## Security and Cost Implications

- **Wider permissions on each spoke.** Argo CD can manage four more
  namespaced kinds there. They stay inside the environment namespace,
  never include Secret, and are listed one by one in all three places
  (TAD R-05).
- **The upgrade is a new way to change the most sensitive component**
  (R-11). It requires confirmation, shows the change first, never prints
  Secret content, and rolls back on mismatch.
- **Cost:** USD 0 (local only).

## Validation Method

- **6.3a, offline:**
  - `check-spoke-access`: the 13 kinds are identical in the AppProject,
    the Role and the inclusions;
  - `check-spoke-access-regression`: 6 cases;
  - `backup-render` passes with `yq` in place of PyYAML;
  - `make validate`.
- **6.3a, live on lab-multicluster (2026-11-18):**
  - Without `CONFIRM`, `argocd-upgrade` listed `ConfigMap/argocd-cm`
    (with the inclusions diff) and the three workloads whose config
    checksum changes, and applied nothing.
  - With `CONFIRM=yes` it upgraded from revision 1. The live manifest
    matched the render, and `make argocd-install` was a no-op again.
  - Every Application stayed Synced/Healthy.
  - After `mc-spoke-register`, Argo CD's identity on dev and uat:
    - may create StatefulSets, PVCs, Jobs and CronJobs in its own
      namespace;
    - may not create them in `default`;
    - may not read Secrets or create DaemonSets.
  - The AppProject change reaches the hub from Git. It is synced and
    checked on the pushed branch before the pull request.
- **6.3b–6.3e:** recorded here as each lands.
