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

- **6.3b — the second and third components, tested in the lab.**
  - **`notes` (Python 3.13, `apps/notes`).** Standard library HTTP
    server plus one hash-pinned driver (`pg8000` and its closure),
    on distroless `python3-debian13`, non-root. `GET`/`POST /notes`,
    `/healthz`, `/readyz` (503 until its table exists, while the
    database is down, or while draining), metrics on their own port
    with the same histogram buckets as smoke. It reads its password
    from a file on every connection, so a rotation needs no restart.
  - **`smoke` gains `GET`/`POST /api/notes`**, forwarded to
    `NOTES_URL` only when that is set (absent: 404 as before).
    Requests are capped at 4 KiB, answers at 1 MiB; a notes 5xx or
    timeout becomes smoke's own 502, so smoke's SLI covers the chain.
  - **`postgres` from its own chart (`charts/postgres-lab`).**
    PostgreSQL 18.6 by digest, one replica, restricted pod (UID 999,
    read-only root filesystem), PVC retained on delete and scale-down.
    Both passwords arrive as files from one ESO `ExternalSecret`; the
    application role is created on first start without superuser,
    database-creation or role-creation rights. NetworkPolicy: 5432
    only from the client pods' labels, no egress.
  - **Credentials stay outside Git.** `make eso-provision-db-secret
    ENV=` creates `eso-source-<env>/db-<env>` with two random
    passwords if absent (never printed, never rotated) and always
    re-applies its reader Role for the two SecretStore identities.
  - **`standard-workload` gains two optional values** (amendment in
    ADR-0006): `extraEnv` (plain configuration only; the schema rejects
    names that look like credentials) and `networkPolicy.egressToPods`
    (egress to labelled pods of the same namespace, one port each).
    Both are empty by default, so existing renders do not change.
  - **One image job, two images.** `image.yml` builds, scans, SBOMs,
    signs and attests `smoke` and `notes` in the same job (a matrix
    would rename the required check). Dependabot watches the notes
    base images and `requirements.txt`; `check-supply-chain` requires a
    hash on every requirement and `--require-hashes` in the build.
- **Changed from the plan (6.3b).** The ApplicationSet per spoke and
  component, the overlays and the promotions move to 6.3c. They need a
  published, signed notes digest, which exists only after this change
  reaches `main`. 6.3b is proven with locally built images on the dev
  spoke instead.

- **6.3c — delivery through Argo CD, per component.** One code change,
  then three promotion pull requests (dev, uat, prod), each moving smoke
  and notes together.
  - **One ApplicationSet per component** (`gitops/bootstrap/values.yaml`
    `components`). smoke keeps exactly its previous render (ApplicationSet
    `platform-environments`, Applications `platform-smoke-<env>`,
    overlays `values-<env>.yaml`): renaming either would cascade-delete
    the running workload. notes and postgres get `platform-notes` and
    `platform-postgres`, Applications `platform-<component>-<env>`, only
    for the environments they list, only in the `local-multicluster`
    profile (`charts/postgres-lab` is a lab chart; the AWS data store is
    decided at 6.4). An empty list renders nothing; an environment
    outside the profile, or a component without a list, fails the
    render.
  - **Promotion per app.** `make promote APP=notes ENV=...` with its own
    ledger (`gitops/promotions/notes.tsv`) and repository, read from
    `image.sh`. notes has one overlay per environment
    (`values-notes-<env>.yaml`), created with its configuration before
    the first promotion, which adds its image block.
    `check-promotion` runs per app and also requires that notes runs
    exactly where the bootstrap values list it, with postgres listed
    alongside.
  - **Deregistering a spoke** waits for every Application aimed at it,
    found by destination, not only smoke's. The postgres PVC stays
    (retention policy) and is deleted by hand.
- **Changed from the plan (6.3c).** notes has no `-aws` overlay: it is
  not delivered to EKS until 6.4, so a copy kept only for agreement
  would be dead configuration.

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
- **A third-party PostgreSQL chart or operator.** Rejected for the lab:
  it brings far more objects and permissions than one StatefulSet needs,
  and the AppProject would have to allow them. A small chart with a
  strict schema is checked offline object by object.
- **Credentials as environment variables.** Rejected: the passwords
  stay files (ADR-0010), read by `POSTGRES_PASSWORD_FILE` and by notes
  on every connection.
- **A matrix generator (clusters × components) with a post-selector.**
  Rejected: which Applications exist would depend on selector behaviour
  over flattened parameters, which this project already saw silently do
  nothing. One ApplicationSet per component is rendered and checked
  offline name by name.
- **Distroless `python3-debian12`.** Rejected after scanning: about 30
  fixable HIGH findings in its Python and libraries; `python3-debian13`
  had none.

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
- **6.3b, offline:** notes unit tests (11) run in the image build;
  smoke `go test -race` including the proxy tests (7);
  `check-postgres-lab-chart`; `check-standard-workload-chart` with the
  `extraEnv` and `egressToPods` cases; `check-supply-chain`; image scan
  with zero fixable HIGH/CRITICAL for both images; `make validate`.
- **6.3b, live on the dev spoke (2026-11-18),** with locally built
  images in namespace `dev`, every object named `notescheck-*` and
  deleted afterwards:
  - both ExternalSecrets `SecretSynced`, three pods Ready, 0 restarts;
  - `POST /api/notes` through smoke returned 201, `GET` read it back;
    an empty body returned notes' 400 unchanged;
  - role `notes` without superuser, createdb or createrole; it owns the
    table;
  - after deleting the postgres pod the rows were still there and notes
    reconnected without restarting;
  - a pod without notes' labels got no answer from postgres:5432; a pod
    with notes' instance label reached postgres;
  - correction (found during 6.3c): the 6.3b record also said such a pod
    got no answer from notes:8080. That probe was invalid: it used
    `pg_isready` against an HTTP port, which reports "no response" for
    any non-PostgreSQL server. By the chart contract (ADR-0006) notes
    accepts its http port from every pod of its namespace, so that pod
    would have been allowed;
  - memory: smoke 4 Mi, notes 29 Mi, postgres 35 Mi.
  - The lab test found one defect, fixed before commit: smoke forwarded
    the body chunked, and notes reads only `Content-Length`. Smoke now
    reads the capped body first; a test asserts the length.
- **6.3c, offline:** the bootstrap render with the default values was
  compared byte for byte with main's in the three profiles: identical.
  `gitops-render`: with notes in dev and postgres in dev and uat it
  renders exactly the three expected ApplicationSets (names, chart paths,
  overlays, environments), none under `aws-eks`, and refuses an
  out-of-profile environment and a missing list. `promote-test`: 8 new
  notes cases (unknown app, overlay missing, order, image block added
  with configuration kept, ApplicationSet/overlay agreement, postgres
  alongside, another app's image in the notes ledger). `make validate`.
- **6.3c code, live (2026-11-18):** hub switched to the branch: no new
  ApplicationSet, smoke's ApplicationSet and Applications kept their
  UIDs, Synced/Healthy; back to `main` the same.
- **6.3c dev promotion, live (2026-11-19),** hub on the promotion branch:
  - `platform-notes` and `platform-postgres` generated
    `platform-notes-dev` and `platform-postgres-dev`, Synced/Healthy;
    smoke's Applications kept their UIDs;
  - first sync left `platform-postgres-dev` OutOfSync on the
    StatefulSet's `volumeClaimTemplates` (API defaults added live); the
    chart now writes `apiVersion`, `kind` and `volumeMode`, and the
    Application went Synced;
  - through smoke: `POST /api/notes` 201 and read back, empty body 400;
    role `notes` without superuser/createdb/createrole, owns the table;
  - an unlabelled pod got no answer from postgres:5432; a pod with notes'
    instance label was accepted;
  - memory: smoke 2 Mi, notes 40 Mi, postgres 51 Mi;
  - hub back to `main`: notes and postgres Applications and pods gone,
    PVC `data-platform-postgres-dev-0` retained.
- **6.3c uat, prod:** recorded with their promotions.
- **6.3d–6.3e:** recorded here as each lands.
