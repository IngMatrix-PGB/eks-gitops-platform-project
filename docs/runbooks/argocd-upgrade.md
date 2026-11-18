# Runbook: Upgrading Argo CD's values on a running cluster

**Phase 6.3a. Local kind labs only. `ACTUAL COST: USD 0`.**

`make argocd-install` refuses on purpose to touch an Argo CD whose values
differ from `lab/argocd/values-lab.yaml`. A reviewed values change
reaches a running Argo CD through one path only
([ADR-0023](../adr/0023-reference-application.md)).

## Steps

1. Change `lab/argocd/values-lab.yaml` in a pull request. If the change
   touches the spokes' `resource.inclusions`, the AppProject and the
   spoke Role must change in the same pull request:
   `make check-spoke-access` compares the three.
2. Look at what would change:

   ```bash
   make argocd-upgrade LAB_CLUSTER=hub
   ```

   - It lists every rendered object that differs, and shows the line
     diff of ConfigMaps. It never prints Secret content.
   - It applies nothing and exits non-zero.
   - A config change also changes the checksum annotations of the Argo
     CD workloads, so they restart.
3. Apply it:

   ```bash
   make argocd-upgrade LAB_CLUSTER=hub CONFIRM=yes
   ```

   - It upgrades with exactly the arguments `argocd-install` uses.
   - It then requires the live manifest to equal the offline render.
     Otherwise it rolls back to the previous revision.
   - On success, `make argocd-install` is a no-op again.
4. If the spoke Role changed, re-apply it on each spoke. This also
   rotates the spoke's 24 h token:

   ```bash
   make mc-spoke-register SPOKE=dev
   ```

## What it refuses

- **Argo CD not installed:** use `make argocd-install`.
- **A different chart than the pinned one:** a chart upgrade is a
  separate decision.
- **A release that is not `deployed`.**
