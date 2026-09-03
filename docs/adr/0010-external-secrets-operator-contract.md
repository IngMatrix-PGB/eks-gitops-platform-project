# ADR-0010: External Secrets Operator contract

**Status:** Accepted
**Date:** 2026-09-03

## Context

Phase 2.6 introduces External Secrets Operator (ESO) support ahead of any
AWS Secrets Manager availability, per the canonical plan
(`.local/evidence/phase-2.6-external-secrets-plan.md`, SHA256
`673f44ad643fc9cacbc213c78eff4c7965aa352f560727d09e2584a36f93db34`). That
plan was split into two bounded phases: **2.6.1 — operator bootstrap**
(this ADR) and **2.6.2 — the environment secret reconciliation contract**
(`SecretStore`/`ExternalSecret`/workload consumption), because the two
differ materially in lifecycle owner, cluster-scoped surface, RBAC shape,
risk profile, and expected change frequency. This ADR is written and
accepted with 2.6.1 implemented; 2.6.2 remains planned, not yet
implemented, consistent with this project's own convention that an
`Accepted` ADR records an approved decision, not necessarily a fully
implemented one.

The pinned chart's own capabilities were verified empirically, not
assumed, by rendering it and inspecting the output before any tracked
file was written (the collision gate required by this phase's
authorization):

- ESO's `scopedNamespace` value is a single string, not a list - there
  is no chart-native way to scope one controller to multiple managed
  namespaces. Two independently-scoped Helm releases is therefore the
  only way to give `staging` and `production` genuinely separate RBAC
  boundaries with this chart.
- ESO's CRDs (25 total) are rendered as **plain chart templates**
  (`templates/crds/*.yaml`, generated at package time), not Helm's
  special top-level `crds/` directory, and carry no
  `helm.sh/resource-policy: keep` annotation. A Helm release that owned
  them would delete them on `helm uninstall` - a whole-cluster-scope
  side effect for what should be a per-environment operation.
- The webhook (`ValidatingWebhookConfiguration`) and cert-controller
  components are **cluster-wide singletons by construction**: the
  webhook's `ValidatingWebhookConfiguration` object names
  (`externalsecret-validate`, `secretstore-validate`) are fixed,
  non-release-qualified strings - rendering them from two Helm releases
  would not merely duplicate them, it would collide (a second
  `helm install`/`apply` of the same cluster-scoped object name owned by
  a different release). This was proven by rendering both releases with
  `webhook.create`/`certController.create` left at their chart default
  (`true`) and inspecting the resulting inventory, before correcting the
  design to disable both on the `production` release.

## Decision

1. **CRD lifecycle is fully decoupled from either environment's
   controller.** The 25 CRDs are applied via `kubectl apply` directly
   (`lab/eso/install.sh`), derived from the pinned, checksum-verified
   chart archive via `helm template --set installCRDs=true ...` and
   filtered to only `kind: CustomResourceDefinition` documents - never
   installed by, or owned by, any Helm release. A separate, explicit,
   destructive removal step does not exist in this phase; ordinary
   `make eso-uninstall` never touches them.
2. **Two scoped Helm releases**, `eso-staging` (namespace `eso-staging`)
   and `eso-production` (namespace `eso-production`), each with
   `scopedRBAC: true` and `scopedNamespace` set to `staging`/`production`
   respectively - converting every `ClusterRole`/`ClusterRoleBinding` the
   controller itself would otherwise need into a `Role`/`RoleBinding`
   scoped to exactly that one workload namespace (verified by rendering,
   not assumed from the chart's own values.yaml comment).
3. **`eso-staging` is the fixed, arbitrary owner of the webhook and
   cert-controller singletons**; `eso-production` runs only its own
   scoped controller (`webhook.create: false`, `certController.create:
   false`). Because `ValidatingWebhookConfiguration` is inherently
   cluster-scoped (not namespaced), one running webhook instance
   validates admission for `ExternalSecret`/`SecretStore` objects in
   **both** environments regardless of which release's Pod happens to
   run it - this is not a coverage gap for `production`.
4. **`rbac.servicebindings.create: false`** on both releases - this
   chart-optional `ClusterRole` (for the unrelated ServiceBinding
   operator ecosystem) is not gated by `scopedRBAC` at all and grants
   cluster-wide `get`/`list`/`watch` on `externalsecrets`; disabling it
   removes an unnecessary cluster-scoped grant this project's design
   does not use.
5. **Image pinning via the `tag@digest` reference form.** This chart's
   own image-rendering helper (`external-secrets.image` in
   `_helpers.tpl`) unconditionally renders `<repository>:<tag>` with no
   native digest field. The multi-arch index digest is therefore carried
   inside the `tag` value itself
   (`v2.10.0@sha256:814117b0fd6d121b03e8ba3b6db1cecbe7449a354fc0fc9c4faf73a37aa221b1`),
   producing the valid OCI reference form `name:tag@digest` - the digest
   is what is actually resolved and pulled; the tag portion is
   informational only. This still satisfies "never a mutable tag alone":
   the bytes pulled are digest-determined regardless of what the tag
   says.
6. **Helm bootstrap outside Argo CD**, mirroring the already-proven
   `lab/argocd/*.sh` pattern exactly (`chart-fetch` → `render` →
   `install` → `status` → `uninstall`). This project's own TAD already
   treats Argo CD's own control-plane installation as imperative,
   outside GitOps; ESO is the same category of thing (a cluster operator
   with CRD/RBAC lifecycle concerns), not a workload.

## Alternatives Considered

- **A single cluster-wide ESO controller** (`scopedRBAC: false`).
  Rejected - this is exactly the default posture the prior gap review
  (ES-03, ES-10) flagged as worth scoping down, and this chart supports
  a strictly better alternative.
- **One controller with `scopedNamespace` covering both environments**.
  Rejected - not supported by this chart version; the value is a single
  string, not a list.
- **Running the webhook/cert-controller from both scoped releases**
  (the chart's own default when `webhook.create`/`certController.create`
  are left unset). Rejected after empirical proof via the collision
  gate: the two `ValidatingWebhookConfiguration` objects would collide
  by name (fixed, non-release-qualified), not merely duplicate.
- **Argo-CD-managed operator** (a dedicated add-on `Application` +
  least-privilege `AppProject`). Rejected - does not change the
  CRD-ownership hazard at all (Argo CD applying the same
  Helm-templated CRDs from two `Application`s hits the identical
  cross-release conflict a plain `helm install` would), while adding a
  materially larger permission surface than this project's imperative
  bootstrap pattern already established for Argo CD itself.
- **Forking the chart to remove the chart-fixed generator-kind RBAC
  grants** (18 generator kinds' `get`/`list`/`watch`, always present
  regardless of `scopedRBAC`). Rejected - these remain namespace-scoped
  (never cluster-wide) once `scopedRBAC: true` is applied; forking an
  upstream, actively-maintained operator chart to shave a read-only
  grant this project does not otherwise use is not a proportionate
  response.

## Consequences

### Positive

- Neither scoped release can read, write, or watch a `Secret`,
  `SecretStore`, or `ExternalSecret` outside its own workload namespace -
  proven by rendering (the collision gate) and, once installed, by
  runtime inspection of the live `Role`/`RoleBinding` objects.
- Uninstalling either (or both) scoped releases can never delete a CRD,
  because neither release ever owns one.
- No wildcard apiGroup, resource, or verb exists anywhere in the
  rendered RBAC (grep-verified against the full rendered output, zero
  matches).
- Every rendered image is digest-pinned; no image is ever referenced by
  a mutable tag alone.

### Negative

- The chart's own generator-kind RBAC floor (18 kinds, `get`/`list`/
  `watch`) and the core-group `secrets`/`configmaps` grants cannot be
  narrowed below what the chart template defines, short of forking it.
  Accepted because they remain namespace-scoped.
- `eso-staging` is a structurally special release (it alone carries the
  webhook/cert-controller) - deleting or corrupting it has a
  cluster-wide admission-control impact that deleting `eso-production`
  does not. This asymmetry is documented here rather than hidden; the
  emergency/rollback procedure in the canonical plan accounts for it.
- Phase 2.6.2 (the actual secret contract a workload consumes) is not
  yet implemented - this ADR intentionally covers only the operator
  bootstrap, per the two-PR boundary decided in the canonical plan.

## Security and Cost Implications

No AWS cost impact (local `kind` cluster only; no AWS account, credential,
or cloud resource is introduced in this phase). No `Secret`, `SecretStore`,
or `ExternalSecret` object is created by Phase 2.6.1 - only the operator
itself. Least-privilege is the explicit target: two namespace-scoped
controllers instead of one cluster-wide controller, with the chart's own
optional cluster-scoped extras (`rbac.servicebindings.create`,
`processCluster*`, `createCluster*`) all explicitly disabled.

## Validation Method

- `make eso-render` / `scripts/validate/check-eso-chart.sh`: offline,
  no-cluster-required proof of every claim in this ADR - exactly 25 CRDs
  render from the decoupled CRD unit and from neither scoped release; no
  `(apiVersion, kind, namespace, name)` tuple is rendered by both scoped
  releases; the webhook/cert-controller singleton renders exactly once
  across the combined set; each controller's `Role` (never `ClusterRole`)
  is scoped to exactly its own namespace; zero wildcard matches; every
  rendered image is digest-pinned.
- `make eso-test-runtime-health` (read-only) and `make eso-test-lifecycle`
  (mutating: install → true no-op → uninstall with CRD retention proof →
  no-op uninstall → restoration install → no-op) - both against the real
  `eks-gitops-lab-lite` cluster via `.local/kubeconfig` only, both
  preserving Argo CD, `platform-bootstrap`, and the standard-workload
  baseline throughout, both proving the global kubeconfig hash and
  current-context are never touched.
- Phase 2.6.2, once authorized, must reference this ADR rather than
  re-litigate the operator-ownership, CRD-decoupling, or RBAC-scoping
  decisions made here.
