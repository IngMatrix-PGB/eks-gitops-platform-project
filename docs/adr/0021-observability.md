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
- Cost: USD 0 (local only).

## Validation Method

- 6.1a: `go test -race` in `apps/smoke` (counts by route and code,
  cumulative buckets, label escaping, unmatched paths never become
  labels, `/metrics` only on the metrics listener, both servers stop on
  shutdown); `check-standard-workload-chart` (metrics port and
  `METRICS_PORT` in every environment, not on the Service, NetworkPolicy
  rule from `monitoring` only, off when disabled, render fails when the
  ports collide, schema rejects invalid namespaces and unknown keys).
- 6.1b–6.1d: recorded here as each lands.
