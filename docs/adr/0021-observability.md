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
- **Logs (6.1d)** only if the measured lab leaves at least 1.5 GiB free
  with the hub, dev and uat; otherwise deferred to the AWS phase by an
  amendment here.

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
  one datasource and parseable queries) and its regression test. Live on
  lab-multicluster: recorded here when installed and measured.
- 6.1c–6.1d: recorded here as each lands.
