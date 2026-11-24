# ADR-0025: Lab identity provider and human roles

**Status:** Accepted
**Date:** 2026-11-24

## Context

ADR-0005 chose Keycloak as the reproducible identity provider for the
local lab only, with direct OIDC to Argo CD and no Dex. ADR-0008
postponed it until a real workload existed. The TAD defines three
standing roles (platform administrator, application developer scoped to
its own namespaces, read-only auditor) and an `admin` kept as
break-glass only.

Measured on main at `433c558`, before Phase 4:

- **Argo CD on the hub:** `admin.enabled: true`, with no OIDC and no
  RBAC policy. The local admin is the only way in.
- **Grafana:** only its own admin.
- **Keycloak:** none in the repository.
- **Docker:** about 2.1 GiB free with the hub, two spokes and
  observability running.

Phase 4 is split into 4a–4e. This ADR records the decisions of 4a, the
identity provider itself. 4b–4e amend it.

## Decision

- **Keycloak on the lab-multicluster hub,** namespace `keycloak`,
  installed imperatively by `make idp-install`, not by Argo CD. Argo
  CD's own login will depend on it (4b), and an Argo CD-managed IdP
  would bring back the bootstrap cycle of R-04.
  - Image `quay.io/keycloak/keycloak:26.8.1`, pinned by its multi-arch
    digest.
  - The pod meets Pod Security `restricted`: non-root, no privilege
    escalation, all capabilities dropped, `RuntimeDefault`, and no
    ServiceAccount token.
- **Dev mode, stateless:** `start-dev` with the embedded dev-file
  database on an emptyDir, plain HTTP inside the cluster.
  - A restart re-imports the realm from Git with the same secrets, so
    there is nothing to back up. Velero's explicit namespace list leaves
    the namespace out.
  - This is never a production shape (ADR-0005).
- **The realm lives in Git with no secret.**
  `platform/identity/realm-platform.json` defines:
  - **groups:** platform-admins, developers-dev, developers-uat,
    auditors;
  - **clients:** `argocd` and `grafana`, both confidential, standard flow
    with PKCE S256, redirects on localhost only, and a flat `groups`
    claim;
  - **test users:** one per role, plus `nogroup-user`, which has no
    group.

  Every client secret and password is a `${KC_*}` placeholder. Keycloak
  resolves the placeholders at import from the Secret
  `keycloak-realm-secrets`, which `make idp-install` generates once and
  keeps on re-runs. The test users' passwords are copied to
  `.local/identity/` (mode 600) for the tests. Nothing secret is
  printed, put on argv, or committed.
- **One issuer for every caller:**
  `http://keycloak.keycloak.svc.cluster.local:8080/realms/platform`
  (`KC_HOSTNAME`). Argo CD and Grafana in the cluster, and the operator
  through a port-forward, get tokens with the same `iss`. Browser login
  needs that name to resolve to the port-forward: one optional
  `/etc/hosts` line, added by the operator (runbook).
- **Password grant on the `argocd` and `grafana` clients, lab only,**
  so the role tests run without a browser. A production IdP would not
  enable it.

## Alternatives Considered

- **Keycloak as an Argo CD Application.** Rejected: Argo CD's login
  would depend on an app Argo CD itself must sync.
- **A Helm chart.** Rejected: the common community chart is no longer
  maintained as open source, and the official Keycloak Operator adds
  CRDs and a controller for one lab instance. Four plain manifests are
  enough and easy to check.
- **Production mode with TLS and PostgreSQL.** Rejected for the lab: it
  adds a database and a certificate authority to prove a login flow.
  4b uses TLS with a lab CA only if Argo CD refuses an HTTP issuer.
- **Secrets in the realm file, or set later through the admin API.**
  Rejected: the first would put credentials in a public repository, and
  the second would lose them on every restart. Placeholders keep Git
  clean and restarts lossless.
- **A different issuer per caller.** Rejected: OIDC validation compares
  `iss` exactly, so in-cluster and operator tokens must agree.

## Consequences

- 4b and 4c configure Argo CD and Grafana against a running, tested
  IdP, with test users already in place for the role matrix.
- The hub runs one more pod of about 0.75 GiB. The install refuses a
  first start with less than 800 MiB of free Docker memory, and
  `IDP_SKIP_MEMORY_CHECK=1` overrides that.
- Rotating every secret means deleting the two Secrets and running
  `make idp-install` again. The pod picks the new values up on its next
  start.

## Security and Cost Implications

- No cost: the lab only.
- Inside the cluster, Keycloak is HTTP; outside, it is reachable only
  through `kubectl port-forward`. It has no Ingress and no
  LoadBalancer.
- The password grant and the `start-dev` mode are lab-only choices,
  recorded here so they are never copied to a real deployment.
- Brute-force protection is on in the realm.

## Validation Method

- `make check-identity`, in `make validate`, checks:
  - the pinned digest and the restricted pod;
  - the issuer is the in-cluster Service name;
  - every secret field in the realm is a placeholder;
  - users, groups and clients equal the tables in
    `scripts/identity/_lib.sh`;
  - redirects are on localhost only, and the `groups` claim is flat.

  `make check-identity-regression` adds 16 mutation cases.
- `make idp-status`, live on the hub, checks:
  - Keycloak is Ready on the pinned image;
  - in-cluster discovery shows the issuer;
  - each test user gets a token with that issuer, audience `argocd` and
    exactly its group;
  - a wrong password is refused.

  It also measures the pod's memory.
