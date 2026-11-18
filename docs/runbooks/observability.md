# Runbook: Observability on lab-multicluster

**Phase 6.1b. Local kind labs only. `ACTUAL COST: USD 0`.**

The metrics pipeline of [ADR-0021](../adr/0021-observability.md):

- each spoke runs Prometheus in agent mode and kube-state-metrics, and
  remote-writes to the hub;
- the hub runs Prometheus, Alertmanager and Grafana.

Everything runs in the namespace `monitoring`. It is installed by make
targets, not by Argo CD. The configs and dashboards live in
`platform/observability/`.

## Prerequisites

- lab-multicluster up with the hub and the spokes you want (`make mc-up`).
  The stack has no role on lab-lite.
- `make tools-install` (helm, kubectl, promtool) and `make obs-chart-fetch`.
- `htpasswd`, for the bcrypt hashes. macOS ships it; on Debian/Ubuntu it
  comes in `apache2-utils`.
- Docker memory: the install refuses a first install when free memory is
  below the role's floor in `scripts/observability/_lib.sh`.
  `OBS_SKIP_MEMORY_CHECK=1` overrides it and says so.

## Install

The hub goes first. A spoke adds its own credential to the hub.

```bash
make obs-install LAB_CLUSTER=hub
```

```bash
make obs-install LAB_CLUSTER=dev
```

```bash
make obs-install LAB_CLUSTER=uat
```

Re-running is a no-op when nothing changed. A changed config or values
upgrade the release and roll the pod. A release on another chart, or not
`deployed`, is refused.

## Check

On a spoke, `make obs-status LAB_CLUSTER=dev` checks that the agent has
sent samples to the hub and that none failed.

On the hub, run:

```bash
make obs-status LAB_CLUSTER=hub EXPECT_CLUSTERS="hub spoke-dev spoke-uat"
```

It checks that:

- a query and a remote write without credentials both get 401;
- every listed cluster has series in the hub;
- Grafana is healthy and its API refuses anonymous calls;
- the datasource reaches Prometheus;
- the platform dashboards exist.

## Open Grafana or Prometheus

Neither is exposed outside the cluster. Use a port-forward against the
hub's kubeconfig:

```bash
.tools/bin/kubectl --kubeconfig .local/kubeconfig-hub -n monitoring port-forward svc/obs-grafana 3000:80
```

The Grafana admin password is in the Secret `obs-grafana-admin`, key
`admin-password`. Read it into your clipboard. Do not paste it into a
terminal you share.

Prometheus is at `svc/obs-prometheus-server`, port 80, and every endpoint
asks for basic auth. To query it, use the `hub` user. Its password is in
the Secret `obs-prometheus-self`.

## Credentials

| Secret | Where | Holds |
|---|---|---|
| `obs-remote-write` | each spoke | that spoke's remote-write password |
| `obs-web-config` | hub | `web.yml` and the user list: one bcrypt hash per user, no password |
| `obs-prometheus-self` | hub | password of user `hub` (Prometheus scraping itself) |
| `obs-grafana-datasource` | hub | password of user `grafana` (the datasource) |
| `obs-grafana-admin` | hub | Grafana admin user and password |

The install script generates all of them and keeps them on re-runs. They
are never in Git, never printed, and never in a Helm release.

Prometheus re-reads `web.yml` on each request. A user change applies as
soon as the kubelet refreshes the mounted Secret, which takes about a
minute.

To rotate a spoke's credential, remove the stack from the spoke and
install it again:

```bash
make obs-uninstall LAB_CLUSTER=dev
```

```bash
make obs-install LAB_CLUSTER=dev
```

## Remove

```bash
make obs-uninstall LAB_CLUSTER=dev
```

Removing a spoke removes its release, its Secret, and its user on the
hub. A credential copied from it then gets 401.

```bash
make obs-uninstall LAB_CLUSTER=hub
```

Removing the hub removes its releases, Secrets and dashboards ConfigMap.
Remove the spokes first, or their remote writes fail until you do.
Neither command deletes the namespace.

## Change a config or a dashboard

1. Edit the file under `platform/observability/`.
2. Run `make check-observability`. It runs promtool on every config,
   checks that each spoke is scoped to its environment and that no
   credential is written inline, and checks that every dashboard uses
   the one datasource and that each query parses.
3. If you changed a pin or values in `scripts/observability/_lib.sh`,
   also run `make obs-render`.
4. After the pull request merges, run `make obs-install` on each member
   to apply it.

## LAB-ONLY

These shortcuts exist only in the lab:

- Plain HTTP between the spokes and the hub, on the local docker network.
- `insecure_skip_verify` towards the kubelets.
- Basic auth with no per-user authorization. Any valid credential can read
  every series (TAD R-15).

The AWS design (TLS, private endpoint, SigV4, or Amazon Managed
Prometheus) is decided at Phase 6.4.
