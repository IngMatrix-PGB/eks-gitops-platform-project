# ADR-0021: Observability for the hub and the spokes

**Status:** Accepted
**Date:** 2026-11-17

## Context

The roadmap (6.1) asks for per-spoke metrics shipped to the hub,
dashboards and logs in the hub, one SLO with unit-tested multi-window
burn-rate alerts, and Argo CD health alerts. Measured on 2026-11-17:
there is no observability component in the repository, and the
first-party workload `apps/smoke` exposes no metrics.

The lab runs on one machine: Docker has 7.65 GiB. lab-multicluster was
measured at about 4.4 GiB with the hub and three spokes, ESO and the
workloads (TAD R-10); the default profile is the hub plus dev and uat.
The observability stack has to fit in what is left, and the measurement
decides how much of it runs locally.

## Decision

- **Stack: upstream Prometheus, Alertmanager and Grafana.** Each spoke
  runs Prometheus in agent mode (scrape and remote write only) and
  kube-state-metrics; the hub runs one Prometheus with the remote-write
  receiver on, Alertmanager and Grafana.
- **Installed like the other add-ons:** charts pinned by version and
  sha256, images by digest, through make targets; not through Argo CD.
- **Spoke → hub:** remote write to the hub's Prometheus over the kind
  network, with one basic-auth credential per spoke, generated at
  install, never in Git. Plain HTTP on the local docker bridge is
  lab-only; TLS and a private endpoint belong to the AWS phase (6.4).
- **Labels:** every spoke series carries `cluster` and `environment`;
  rules and dashboards group by `cluster`.
- **The workload's metrics (6.1a):** `apps/smoke` serves
  `http_requests_total{route,code}`,
  `http_request_duration_seconds{route}` (histogram) and
  `smoke_build_info{version}` in the Prometheus text format, written with
  the standard library, on its own port (`METRICS_PORT`, 9090). `route`
  is the declared route or `unmatched`, never the path a client sent.
  The standard-workload chart renders a `metrics` container port and a
  NetworkPolicy rule that opens it only to the namespaces in
  `metrics.scrapeFromNamespaces` (default `monitoring`); the Service
  never exposes it.
- **One SLO:** smoke availability, share of `/` and `/api/info`
  requests not answered 5xx, 99.5 % over 30 days, with multi-window
  multi-burn-rate alerts (14.4× over 1h and 5m, 6× over 6h and 30m, 3×
  over 1d and 2h, 1× over 3d and 6h).
- **Argo CD alerts:** application Degraded, OutOfSync for too long,
  failed sync, controller down.
- **Rules are tested:** `promtool check rules` and `promtool test rules`
  in `make validate`, with a pinned, checksum-verified `promtool`.
- **Dashboards as code:** JSON in the repository, provisioned into
  Grafana with the hub Prometheus as the only datasource.
- **The pipeline (6.1b), as built:**
  - Pins: prometheus-community `prometheus` chart 29.40.3 and
    grafana-community `grafana` chart 14.3.1 (the Grafana chart moved to
    that repository), Prometheus v3.15.1, Alertmanager v0.34.2,
    kube-state-metrics v2.20.0, Grafana 13.3.0 (distroless), each by
    index digest; `promtool` v3.15.1 from the Prometheus release archive.
  - One namespace, `monitoring`, on every member, Pod Security
    `restricted`; one Helm release `obs` (prometheus chart) per member and
    `obs-grafana` on the hub.
  - The Prometheus config is ours, in `platform/observability/`, not the
    chart's generated one; the chart's RBAC is off. A spoke may read
    nodes and `nodes/metrics` cluster-wide and pods only in its
    environment namespace; kube-state-metrics only that namespace. The
    hub reads nothing from the API and mounts no service account token.
  - Spoke scrape jobs: the agent itself, kubelet cAdvisor (four container
    CPU and memory series kept; `insecure_skip_verify` LAB-ONLY, as for
    metrics-server), kube-state-metrics (Deployments, Pods, HPAs), and the
    workload's `metrics` port in the environment namespace.
  - Hub: the remote-write receiver on a NodePort (30090) of the hub node;
    every endpoint behind basic auth from a web config holding one bcrypt
    hash per user (`spoke-<env>`, `hub` for its own scrape, `grafana` for
    the datasource). Kubelet probes are TCP, so no password sits in the pod
    spec; there is no config-reloader sidecar, a changed config rolls the
    pod. Alertmanager has a `null` receiver.
  - Grafana: anonymous access off, generated admin credential, one
    datasource (UID `hub-prometheus`) whose password comes from the
    environment, dashboards from a ConfigMap the install script builds
    (the chart's own `dashboards` value adds a curl init container).
  - NetworkPolicy, ingress: default deny in `monitoring`; the hub
    Prometheus port open (spokes arrive through the NodePort, basic auth
    gates them); Alertmanager and Grafana only from the hub Prometheus;
    kube-state-metrics only from the agent.
  - Changed from the plan: scraping Argo CD's metrics, and the SLO and
    Argo CD dashboards, move to 6.1c with the rules that use them. 6.1b
    ships two dashboards: clusters overview and the smoke workload.
- **The SLO and the alerts (6.1c), as built:**
  - Rules in `platform/observability/rules/`, loaded by the hub
    Prometheus from the same ConfigMap as its config (a change rolls the
    pod). Recording rules
    `cluster:smoke_http_errors:ratio_rate{5m,30m,1h,2h,6h,1d,3d}`: 5xx
    share of `/` and `/api/info` per `cluster`; 0 rather than absent when
    there are no errors, absent when there is no traffic.
  - Burn-rate alerts `SmokeAvailabilityBudgetBurn{Fast,High,Medium,Slow}`
    at 14.4x, 6x, 3x and 1x of the 0.005 budget, each requiring its long
    and short window, labeled `severity` (page or ticket), `slo` and
    `burn_rate`.
  - Argo CD alerts: `ArgoCDApplicationDegraded` (10m),
    `ArgoCDApplicationOutOfSync` (30m), `ArgoCDApplicationSyncFailed` (a
    failed or errored sync in the last 10m) and
    `ArgoCDApplicationControllerDown` (5m, also when not scraped at all),
    grouped by application and destination.
  - Argo CD's metrics come from the hub's application controller through
    a Service the `obs` release adds in the `argocd` namespace (selector
    on the controller pods, port `metrics`). Changed from the plan:
    enabling the chart's metrics Service would change the Argo CD values,
    which `make argocd-install` refuses on an installed hub by design;
    the controller's own NetworkPolicy already admits its metrics port.
    Only the application controller is scraped: every alert needs only
    its metrics.
  - Unit tests in `platform/observability/rules/tests/`, run by `make
    check-observability`. It also requires that every alert is expected
    to fire in some test case, and every SLO alert also to stay silent in
    one.
  - Dashboards added: SLO (availability and budget left over the stored
    window, burn rate per window, error ratio, firing SLO alerts) and
    Argo CD (applications by health and sync, controller up, sync
    operations, firing Argo CD alerts).
  - Live fire test: only the Argo CD family. `apps/smoke` has no failure
    mode that answers 5xx on its user routes, so no live SLO alert can be
    produced without injecting failures into the workload. The plan's
    lab-only short-window copy of the rules was dropped: with no 5xx it
    would prove nothing beyond the unit tests. Live, the SLO is checked by
    its recording series existing for every spoke.
- **Logs (6.1d)** only if the measured lab leaves at least 1.5 GiB free
  with the hub, dev and uat; otherwise deferred to the AWS phase by an
  amendment here. Measured 2.75 GiB free, so built:
  - **Hub:** Loki 3.6.16 in single-binary mode (`grafana` chart 7.5.0, the
    line Grafana Labs maintains) on an `emptyDir`.
    - Retention is 72 h through the compactor, with explicit ingestion
      limits and one tenant.
    - It renders no PersistentVolumeClaim, so removing it never deletes a
      volume.
    - Loki is reachable only through the chart's nginx gateway. The
      gateway enforces basic auth from the same per-user bcrypt hashes as
      the Prometheus web config (an `.htpasswd` key in the same Secret)
      and sits on NodePort 30100.
  - **Spokes:** Fluent Bit 5.1.3 (`fluent-bit` chart 0.58.3), a
    DaemonSet in its own namespace, `logging`.
    - It tails only `/var/log/containers/*_<env>_*.log` and reads
      namespace, pod and container from the file name. That needs no
      Kubernetes API access, so it has no RBAC and no service account
      token.
    - It pushes with the spoke's existing credential (`spoke-<env>`). The
      same password covers metrics and logs; removing the spoke revokes
      both, and the uninstall waits until both refuse it.
  - **The one exception to `restricted`:** reading node log files needs a
    read-only `hostPath` of `/var/log` and the root user. `logging` is
    therefore enforced at `privileged` (with `restricted` audited and
    warned).
    - The pod is otherwise locked down: read-only root filesystem, every
      capability dropped, no privilege escalation, RuntimeDefault seccomp,
      no token, no host network. Ingress to `logging` is denied.
    - `obs-render` enforces exactly this (TAD R-17).
    - On EKS the log path is decided at 6.4.
  - **Grafana:** a second provisioned datasource, `hub-loki`, and the
    dashboard "Platform / Logs". `check-observability` accepts exactly
    the two datasource UIDs, one per panel, and requires every LogQL
    query to select on `cluster`.
  - **Changed from the plan:** the agent's position database is on an
    `emptyDir`, not the host, so there are fewer host writes. Files are
    read from the start on first sight, because the workload logs little
    after it starts. On a restart lines are sent again; Loki drops exact
    duplicates and rejects lines older than 24 h.

## Alternatives Considered

- **kube-prometheus-stack with the Prometheus Operator.** Rejected for
  the lab: CRDs and more pods per cluster, in a memory budget that is
  already the constraint, for nothing the plain charts cannot do.
- **Thanos or Mimir.** Rejected: object storage and several components
  for three or four clusters.
- **Amazon Managed Prometheus and Managed Grafana.** Not decided here:
  chosen against a self-hosted hub at 6.4, with a measured cost. The
  spoke side (agent and remote write, SigV4 on AWS) has the same shape
  either way.
- **The Prometheus Go client library in `apps/smoke`.** Rejected: three
  metric families do not justify a dependency tree in the image whose
  supply chain ADR-0017 keeps minimal.
- **Metrics on the application port.** Rejected: `/metrics` would be
  reachable by every client of the Service.

## Consequences

- Promoting the new image is what turns the metrics on in each
  environment; until then the chart's `metrics` port is open but nothing
  listens on it.
- The SLO is proved by unit tests: lab traffic is sparse and the service
  has no failure mode of its own.
- Chart and image pins of the stack age like those of ESO and
  metrics-server; Dependabot does not see them.

## Security and Cost Implications

- No credential in Git; one remote-write credential per spoke, so
  removing a spoke removes its access, as for Argo CD (R-11).
- The workload's metrics port is reachable only from the monitoring
  namespace.
- Basic auth in Prometheus authenticates but does not authorize: any
  valid credential, a spoke's included, can read every cluster's series
  and write any series. Accepted for the lab (TAD R-15); per-identity
  write access is part of the AWS design.
- Cost: USD 0 (local only).

## Validation Method

- 6.1a: `go test -race` in `apps/smoke` (counts by route and code,
  cumulative buckets, label escaping, unmatched paths never become
  labels, `/metrics` only on the metrics listener, both servers stop on
  shutdown); `check-standard-workload-chart` (metrics port and
  `METRICS_PORT` in every environment, not on the Service, NetworkPolicy
  rule from `monitoring` only, off when disabled, render fails when the
  ports collide, schema rejects invalid namespaces and unknown keys).
- 6.1b, offline: `make obs-render` (object sets per role, pinned
  digests, restricted pods, no Secret in any release, least RBAC, TCP
  probes and one NodePort on the hub, agent mode and credential wiring on
  the spoke); `make check-observability` in `validate` (promtool on every
  config, per-environment scoping, no inline credential, dashboards with
  one datasource and parseable queries) and its regression test.
- 6.1b, live on lab-multicluster (hub, dev, uat; 2026-11-18):
  - `make obs-install` on each member, then `make obs-status`: every
    target `up` (11: three on the hub, four per spoke); unauthenticated
    query and remote write answered 401; each spoke's series labeled with
    its own cluster and environment and only from its own namespace;
    Grafana healthy, anonymous API refused, datasource reachable, every
    dashboard query answered through it.
  - NetworkPolicy, from a pod in another namespace: kube-state-metrics,
    the agent, Alertmanager and Grafana time out; the hub Prometheus
    answers 401.
  - Re-running the install changes nothing. Removing a spoke waits until
    the hub refuses its old credential (401 after 40 s, the kubelet's
    refresh of the mounted web config); reinstalling it waits until the
    hub accepts the new one before the agent starts, so no sample is
    refused (the first install, before that wait existed, lost about a
    minute of samples to 401).
  - Memory (Docker view): hub node +0.77 GiB (Prometheus 63 Mi,
    Alertmanager 18 Mi, Grafana 247 Mi), each spoke's agent and
    kube-state-metrics about 65 Mi; about 2.8 GiB stay free with hub, dev
    and uat. That clears the 1.5 GiB gate, so 6.1d (logs) proceeds.
- 6.1c, offline: `promtool check rules` and `promtool test rules` in
  `make check-observability`. 12 test cases:
  - each alert fires;
  - each SLO alert stays silent below its threshold;
  - an alert needs both its windows, so it resolves once the errors stop;
  - one spoke's errors never fire for another;
  - errors on probes or unmatched paths are not counted;
  - no traffic records nothing.

  The regression test rejects seven more mutations, including:
  - a fast-burn alert without its short window;
  - an error ratio that loses `cluster`;
  - an SLI over every route;
  - a Degraded alert with `for: 1m`;
  - an alert with no firing test;
  - a rule file without tests.
- 6.1c, live on lab-multicluster (2026-11-18):
  - All 15 rules were loaded and healthy.
  - The Argo CD controller was scraped (`up=1`) and the three
    applications appeared Healthy and Synced.
  - Under ~1.7 requests/s of generated traffic, the recording series
    existed for spoke-dev and spoke-uat with value 0.
  - Every query on the four dashboards answered through Grafana.
  - Fire test: the controller was scaled to 0.
    `ArgoCDApplicationControllerDown` reached Alertmanager after 361 s
    (`severity=page`, `cluster=hub`). It was resolved after scaling back
    to 1, and the applications were still Synced and Healthy.
- 6.2a (ADR-0022) adds `backup.rules.yml` with five backup-health
  alerts and the `velero` scrape job on every member, under this ADR's
  rules contract.
- 6.1d, offline: `make obs-render`.
  - **Loki:** object set, pinned digests, restricted pods, a ClusterRole
    with no rules, no PersistentVolumeClaim, retention and tenancy, one
    NodePort, gateway basic auth.
  - **Fluent Bit, for each of dev, uat and prod:** scoped to its own
    namespace, labeled and authenticated as its spoke, `hostPath` exactly
    `/var/log` read-only, root with everything else locked down, no
    token, no RBAC, no Secret.

  `make check-observability` covers the dashboards' two datasources and
  LogQL selectors, with 3 more regression mutations.
- 6.1d, live on lab-multicluster (2026-11-18):
  - Loki, its gateway and Fluent Bit run on hub, dev and uat.
  - The hub has log streams for spoke-dev and spoke-uat, labeled
    `cluster`, `environment`, `namespace`, `pod` and `container`, from
    namespaces `dev` and `uat` only. The lines are the workload's own
    JSON.
  - A push without credentials gets 401, and the Grafana Loki datasource
    is healthy. Every query on the logs dashboard answers through Grafana.
  - NetworkPolicy: from another namespace, Loki itself and the agent's
    port time out, and the gateway answers 401.
  - Removing uat: the hub refused its old credential on Prometheus after
    10 s and on the Loki gateway after 41 s. Reinstalling waited for both
    to accept the new one.
  - Memory: the hub node grew +0.28 GiB (Loki 96Mi, gateway 12Mi);
    Fluent Bit used 4Mi per spoke. About 2.5 GiB stay free with hub, dev
    and uat.
  - Found and fixed live:
    - the custom parser file was not loaded;
    - nothing was sent from files that existed before the agent started;
    - lines were wrapped as `time=... log=...`;
    - the agent mounted a service account token. `obs-render` now checks
      for that last one.

## Amendment (Phase 6.3e, 2026-11-19): the reference application

- The spoke scrape job `workload` adds a `release` label (the Argo CD
  Application name). smoke and notes share `app=standard-workload`;
  `release` tells them apart.
- smoke's availability SLO now also counts `/api/notes`. smoke answers
  502 when notes or its database fails, so the SLI covers the whole
  chain. A unit test fails only `/api/notes` and expects the fast burn
  to fire.
- Each spoke's kube-state-metrics also collects statefulsets, jobs and
  cronjobs. These are read-only and limited to the environment
  namespace.
- `reference-app.rules.yml` adds five `ticket` alerts, each unit-tested:
  - `NotesDown`;
  - `NotesNotReady`;
  - `PostgresDown`;
  - `NotesDumpFailed`: the newest scheduled dump has not succeeded 15
    minutes after it was scheduled;
  - `NotesDumpMissing`: no success for 13 hours, including a CronJob
  that never succeeded.
- Dashboard "Platform / Reference application": notes traffic, errors
  and p95; smoke's `/api/notes` answers; notes and postgres readiness;
  the age of the last dump.
