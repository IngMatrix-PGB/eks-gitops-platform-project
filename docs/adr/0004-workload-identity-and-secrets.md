# ADR-0004: Workload identity and secrets

**Status:** Accepted
**Date:** 2026-08-31

## Context

Workloads need AWS access without long-lived static credentials, and
secret values without those values ever entering Git. Two general risks
shape this design: first, EKS Pod Identity and IRSA are structurally
different mechanisms that are easy to conflate, and an implicit naming
convention between an infrastructure tool and a workload chart is a
known source of silent production failures. Second, a namespace-scoped
secret store only controls where a Kubernetes object can be
*referenced* — it says nothing about what the controller behind it can
actually reach in AWS; treating Kubernetes-side scoping as a complete
security boundary is a known way isolation ends up nominal only.

## Decision

### Workload identity

**EKS Pod Identity is the default**; **IRSA is an explicit compatibility
path**, never a silent fallback. The two are not interchangeable:

| | EKS Pod Identity | IRSA |
|---|---|---|
| `ServiceAccount` annotation | None (`eks.amazonaws.com/role-arn` is not used) | Normally present, read by the IRSA webhook |
| Required component | EKS Pod Identity Agent | An OIDC provider on the cluster |
| Identity binding | Terraform-managed association: (cluster, namespace, `ServiceAccount` name) → IAM role | IAM role trust policy scoped to a namespace/`ServiceAccount` subject |
| Credential delivery | Standard AWS SDK default credential chain | IRSA webhook injection based on the annotation |

The standard chart (ADR-0006) exposes an explicit `identityMode`:
`podIdentity` (no IAM annotation invented), `irsa` (an explicit
`roleArn` is required, and rendering fails clearly if it's missing), or
`none`. The contract that must be tested is the tuple **(cluster,
namespace, `ServiceAccount` name)** — never an implicit guess based on
matching role *names*. `kind` can validate the shape of that contract;
it cannot prove EKS Pod Identity itself, since it has no AWS
control-plane integration. The real positive/negative proof — an
authorized workload can act, an unauthorized one cannot — is only
demonstrated against a real, temporary, explicitly authorized EKS
cluster.

### Secrets

External Secrets Operator (ESO) reconciles secret values from **AWS
Secrets Manager**, under a layered isolation model — not a single
Kubernetes object:

1. IAM least privilege for whatever identity each ESO instance uses.
2. Kubernetes RBAC governing who can create/read `SecretStore`/
   `ExternalSecret` objects.
3. Each ESO controller's own identity, authenticated via EKS Pod
   Identity.
4. Per-namespace/tenant **assumable roles** where feasible — the
   controller assumes a role scoped to the namespace/tenant it is
   reconciling for, rather than one broad role for every secret.
5. AWS Secrets Manager's own resource policies.

**ESO runs as a separate instance in every cluster that needs to create
Kubernetes `Secret`s — `management` (control-plane secrets only, e.g.
Argo CD's OIDC client secret, if needed), `staging`, and `prod`. No ESO
controller instance is shared across clusters** — each has its own Pod
Identity association, its own `SecretStore`s, and its own IAM roles,
fully separate from the others.

A namespace-scoped `SecretStore` is the default in every cluster,
referencing that cluster's own correspondingly scoped role. **The real
isolation boundary is the combination of the layers above — IAM, RBAC,
each cluster's own controller identity, and per-tenant role scoping —
never the namespace-scoped `SecretStore` object by itself.** If any
cluster's controller identity is over-privileged, that cluster's
namespace-scoped stores become a nominal separation only (tracked in the
TAD's risk table as a per-cluster, per-tenant risk). `ClusterSecretStore`
remains an exception requiring a separate, explicit decision, evaluated
independently for each cluster if ever proposed.

## Alternatives Considered

- **Letting the chart infer or guess an identity mode or role ARN by
  convention**: rejected — reintroduces an untested implicit contract.
- **One broad ESO controller role for every namespace, relying only on
  `SecretStore` Kubernetes-side scoping**: rejected as the default — this
  is exactly the nominal-isolation failure mode this ADR exists to avoid.
- **A single ESO controller instance shared across `management`,
  `staging`, and `prod`**: rejected — it would need broad, cross-cluster
  reach to create `Secret`s in clusters it does not otherwise operate
  in, concentrating exactly the kind of over-privileged identity this
  ADR is designed to prevent.
- **Kubernetes-native `Secret` objects or Git-committed encrypted
  secrets**: rejected — both keep secret material passing through
  Git-adjacent systems.

## Consequences

### Positive

- Pod Identity removes per-workload OIDC trust-policy templating for the
  default path, while IRSA stays available for add-ons that need it.
- Secret isolation does not rest on a single Kubernetes-side control.

### Negative

- Two identity mechanisms and a multi-layer secrets model must be
  documented and tested, not just one of each.
- The per-namespace/tenant assumable-role pattern adds operational
  complexity, accepted deliberately in exchange for real AWS-side
  isolation.

## Security and Cost Implications

Directly targets two known risks: an untested identity naming
convention, and an over-privileged secrets controller silently defeating
namespace isolation. No cost beyond the EKS cluster and Secrets Manager's
per-secret/per-API-call pricing (estimated in Phase 4, not incurred yet).

## Validation Method

A `kind`-runnable shape test (chart renders the right `ServiceAccount`
per `identityMode`, fails clearly when `irsa.roleArn` is missing); a
positive/negative test against a real, temporary, authorized EKS cluster
for Pod Identity; a demo `ExternalSecret` reconciliation/rotation test;
and a negative test confirming one namespace/tenant's `SecretStore`
cannot resolve another's secret. All `NOT IMPLEMENTED` today.
