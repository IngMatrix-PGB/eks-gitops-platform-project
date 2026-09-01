# ADR-0005: SSO, bootstrap, and cluster access

**Status:** Accepted
**Date:** 2026-08-31

## Context

Human access to Argo CD needs a reproducible identity provider, and
bootstrapping it introduces a specific ordering problem: Argo CD's OIDC
client secret ideally should be managed like any other secret (via
External Secrets Operator), but ESO is itself a workload Argo CD needs to
have already deployed. An undocumented bootstrap order is a common source
of "we had to do something insecure just to get started" shortcuts that
never get revisited. Separately, remote cluster access for a GitOps
controller defaulting to a broad, convenient credential (e.g. merged
cluster-admin kubeconfigs) is a known way least privilege quietly erodes.

## Decision

### Local IdP

**Keycloak is the reproducible identity provider for the local lab
only.** Argo CD connects to it via **direct OIDC** — no Dex broker in
the initial design. Dex is added later only if a concrete multi-connector
need is demonstrated. **This ADR does not assert that Keycloak will be
the production identity provider** — the local flow exists to prove the
OIDC/RBAC mechanics (a human authenticates, is mapped to a role, and that
role is enforced) without imposing a specific provider on the eventual
AWS deployment.

### Human identity in AWS vs. Argo CD's production IdP

- **AWS IAM Identity Center** covers human access to AWS and to EKS
  (access entries) — this is settled, not open (see the TAD's "Human
  Identity and SSO").
- **Which OIDC identity provider Argo CD uses in AWS is `UNKNOWN`**,
  pending an explicit decision. It could be IAM Identity Center itself
  (if it can act as an OIDC provider for Argo CD), Keycloak deployed in
  AWS, or another IdP entirely. This ADR intentionally does not decide
  it — deciding it prematurely, before a real deployment's constraints
  are known, would risk locking in a choice for the wrong reasons.

### Local bootstrap secret handling

- The Keycloak↔Argo CD OIDC client secret is generated during local
  bootstrap.
- It is stored **only as an ephemeral, in-cluster Kubernetes `Secret`**
  inside the disposable `kind` cluster — never written to Git or any
  persistent file.
- Local bootstrap tooling may record `kind` cluster contexts in the local
  kubeconfig — acceptable specifically because `kind` clusters are
  disposable, and not a precedent for how any remote credential is
  handled.

### AWS bootstrap ordering

1. Argo CD may **initially bootstrap without SSO enabled** — a local
   administrative credential is an acceptable starting point.
2. **The `management`-cluster ESO instance and its secrets path are
   installed before** the final OIDC configuration is activated, since
   the OIDC client secret is meant to be reconciled through that
   control-plane ESO instance once it exists (see ADR-0004 — ESO runs
   per cluster; this ordering concerns specifically the instance in
   `management`).
3. The secret then lives in **AWS Secrets Manager** and is reconciled via
   ESO — never introduced into Git.
4. **How that secret is first seeded into Secrets Manager is `UNKNOWN`**,
   pending an explicit Phase 4 decision. Whatever mechanism is chosen,
   **Terraform must never store that plaintext value in state.**
5. Argo CD's authentication mechanism toward **remote EKS clusters** (if
   a multi-cluster/hub topology is adopted) must be designed for least
   privilege in Phase 3/4 — **not assumed solved** by default
   cluster-admin kubeconfig merging.

## Alternatives Considered

- **Dex in front of Keycloak from the start**: rejected — adds a
  component with no concrete need yet.
- **Requiring OIDC fully configured before Argo CD can start at all**:
  rejected — forces solving the ESO-before-OIDC ordering problem before
  Argo CD can run even once; starting without SSO and layering it in is
  simpler to sequence.
- **Storing the OIDC secret's initial value as a plain Terraform
  variable/resource argument**: rejected — exactly the "plaintext in
  state" outcome this ADR prohibits.
- **Static Argo CD `admin` password as the standing operational path**:
  rejected — `admin` is a bootstrap/break-glass fallback, not the normal
  path once OIDC is configured.
- **Deciding now that Keycloak (or any other specific IdP) will be
  Argo CD's production identity provider in AWS**: rejected — the local
  lab's job is to prove the OIDC/RBAC mechanism works, not to lock in a
  production IdP before Phase 3/4 constraints are known.

## Consequences

### Positive

- Fewer moving parts for the local lab's SSO path.
- The Argo CD/ESO/OIDC-secret bootstrap ordering is named and sequenced
  explicitly instead of discovered the hard way during a real rollout.
- Local ephemeral-secret handling never accumulates a persistent,
  git-adjacent copy of a credential, even a throwaway one.

### Negative

- If a genuine multi-connector need appears later, Dex is a follow-up
  change, not assumed to already be there.
- The OIDC-secret initial-seeding mechanism remains an open question
  until Phase 4.
- Least-privilege remote-cluster credentials for a possible multi-cluster
  topology are deferred, adding design work to Phase 3/4.
- Which IdP Argo CD uses in production AWS remains genuinely `UNKNOWN`
  until a separate, explicit decision — this ADR deliberately does not
  resolve it.

## Security and Cost Implications

No AWS service charges in the local lab; Keycloak and ESO consume local
compute resources. The explicit prohibition on Terraform state holding a
plaintext secret is a direct control against a well-known
infrastructure-as-code credential leak.

## Validation Method

A test confirming a human can authenticate to Argo CD via Keycloak OIDC
in the local lab and is mapped to a defined role — proving the
OIDC/RBAC mechanism, not a production IdP choice; a check that no
Terraform state file contains the OIDC secret's plaintext value; and,
once a remote-cluster topology exists, a least-privilege review of Argo
CD's cluster credentials. All `NOT IMPLEMENTED` today.
