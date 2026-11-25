# ADR-0025: Lab identity provider and human roles

**Status:** Accepted
**Date:** 2026-11-24 (4a), amended 2026-11-24 (4b, 4c) and 2026-11-25 (4d)

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
identity provider itself, of 4b, Argo CD's login and roles, of 4c,
Grafana's, and of 4d, human access to AWS as code. 4e amends it.

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

### 4b — Argo CD login, roles and break-glass

Measured on the hub before 4b's design, with the admin still on:

- Argo CD v3.5.2 accepts the `http://` issuer: no TLS or lab CA is
  needed.
- An `id_token` from the `argocd` client is accepted as a bearer token,
  so the role matrix runs on the API without a browser.
- Turning `admin.enabled` off makes Argo CD refuse the admin's existing
  token (401 within 5 s) and new logins, with no restart. Turning it on
  works the same way.
- A local login increments
  `grpc_server_handled_total{grpc_service="session.SessionService",grpc_method="Create",grpc_code="OK"}`
  on the API server. SSO and bearer tokens never call it.

Decision:

- **Direct OIDC to Keycloak** in `lab/argocd/values-lab.yaml`
  (`oidc.config`): the lab issuer, client `argocd`, and the client secret
  only by reference, `$argocd-oidc:clientSecret`. `make idp-install`
  writes the Secret `argocd/argocd-oidc` (label `part-of=argocd`) from
  `keycloak-realm-secrets`. `url` is `https://localhost:8443`, the
  address of `make argocd-port-forward`, so the SSO callback is the
  realm's allowed redirect.
- **Roles by group, nothing by default:** `policy.default` is empty and
  `scopes` is `[groups]`.

  | Group | Role | Grants |
  |---|---|---|
  | platform-admins | `role:admin` | everything |
  | auditors | `role:readonly` | read everything, no sync |
  | developers-dev | `role:developer-dev` | get, sync and logs on `platform/platform-*-dev`; get on project `platform` |
  | developers-uat | `role:developer-uat` | the same on `platform/platform-*-uat` |
  | none | none | signed in, sees nothing |

  The root `platform-bootstrap` matches no developer pattern.
- **The local admin is break-glass only.** `admin.enabled` is `false` in
  the committed values. `make argocd-breakglass CONFIRM=yes REASON=...
  [HOURS=1..8]` (default 1) turns it on:
  - it records who, why, when and the expiry as annotations on
    `argocd-cm`;
  - it posts `ArgoCDBreakGlassActive` to the hub's Alertmanager, ending
    at the expiry.

  `make argocd-breakglass-off` turns the admin off, removes the record
  and resolves that alert. `make argocd-breakglass-status` fails while
  the admin is on past its expiry, or on with no record. The next
  `make argocd-upgrade` also turns it off, since the values say `false`.
  If Alertmanager is down, break-glass still works and prints a warning:
  it is for when things are broken.
- **Every local login pages.** The hub's Prometheus scrapes the API
  server (Service `obs-argocd-server-metrics`, added by
  `make obs-install`). `ArgoCDLocalAdminLogin` fires on any successful
  session create in 10 minutes. `ArgoCDServerDown` (5 minutes unscraped)
  says when that alert would be blind.
- **Clusters without Keycloak** (lab-lite, the EKS session) get the same
  values. SSO login fails there, and access is through kubectl or
  break-glass until 4e decides the AWS identity provider.

### 4c — Grafana login and roles

- **Generic OAuth to Keycloak** in the Grafana values
  (`scripts/observability/_lib.sh`): client `grafana`, PKCE, and the
  auth, token and userinfo URLs on the lab issuer. `root_url` is
  `http://localhost:3000`, so the callback is the realm's allowed
  redirect.
- **The client secret is never in the values.** Grafana reads it as
  `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` from the optional Secret
  `monitoring/obs-grafana-oidc`. `make idp-install` writes it and
  restarts Grafana only when the value is new or changed, since Grafana
  reads its environment only at start. Optional means Grafana still
  starts without it: SSO then fails and the local admin works.
- **Roles from the `groups` claim:**

  | Group | Grafana role |
  |---|---|
  | platform-admins | Admin |
  | auditors, developers-dev, developers-uat | Viewer |
  | none | refused |

  `role_attribute_strict` refuses a user whose groups map to no role,
  the same rule as Argo CD's empty default. That is stricter than the
  Phase 4 plan, which gave everyone else Viewer. SSO never makes a
  Grafana server admin, and the role is synced on every sign-in.
- **The local admin stays** as Grafana's own break-glass (Secret
  `obs-grafana-admin`), and every local sign-in pages:
  `GrafanaLocalAdminLogin` fires on any increase of
  `grafana_api_login_post_total` in 10 minutes. Measured: a refused
  password does not count, and OAuth sign-ins count in their own
  counter. SSO users have no local password, so a local sign-in is the
  admin. Unlike Argo CD there is no on/off switch: the Grafana admin
  also runs the stack's own checks, through basic auth, which does not
  count as a sign-in.
- **Measured:** Grafana 13 lets a Viewer list data sources
  (`/api/datasources` answers 200). The line between the roles is the
  `datasources:write` permission, and the live test checks that.

### 4d — Human access to AWS through IAM Identity Center (code only)

A new root, `terraform/envs/identity-center`, offline-tested and never
applied. It belongs in the account that holds the Identity Center
instance: the management account, or its delegated administrator.

- **Inputs, not lookups:** the instance ARN, the identity store ID and
  the account IDs (`terraform/envs/org` output `account_ids`) are
  variables. No data source, so a plan never calls AWS.
- **Groups in Identity Center's own directory,** with the lab realm's
  names plus `breakglass`: platform-admins, developers-dev,
  developers-uat, auditors, breakglass. People join groups outside
  Terraform.
- **Four permission sets, AWS managed policies only:**

  | Permission set | Policies | Session |
  |---|---|---|
  | PlatformAdmin | AdministratorAccess | 1 h |
  | Developer | ViewOnlyAccess, plus an inline `eks:DescribeCluster` on the project's clusters | 1 h |
  | ReadOnly | ReadOnlyAccess, SecurityAudit | 4 h |
  | BreakGlass | AdministratorAccess | 1 h |

  The inline policy has no wildcard action and no `Resource "*"`.
- **Standing access as data:**
  - admins administer platform, dev and uat, and read security and
    prod;
  - developers see their own environment's account;
  - auditors read every account;
  - break-glass has nothing.

  Prod has ReadOnly only.
- **Time-bound elevation as code (D-5):**
  - `elevations.auto.tfvars.json` lists the grants beyond standing
    access, each `{group, permission_set, account, starts_at,
    expires_at, reason}`;
  - Terraform refuses an entry with no expiry, times other than UTC
    `Z`, an expiry not after the start, more than 8 hours, a short
    reason, a duplicate, or one repeating standing access;
  - `make check-elevations`, in `validate`, fails once an entry has
    expired, or when it starts more than 7 days ahead. An expired grant
    therefore blocks every pull request until a change removes it, and
    that change's apply removes it from AWS.
- **EKS:** `terraform/envs/eks` takes two optional, path-less Identity
  Center role ARNs:
  - `developer_principal_arn`: `AmazonEKSViewPolicy` in the
    environment's namespace, dev and uat only;
  - `readonly_principal_arn`: `AmazonEKSViewPolicy` on the cluster.

  PlatformAdmin and BreakGlass map to the existing admin and breakglass
  entries.
- **The emulator now routes `ssoadmin` and `identitystore`.**
  `check-terraform-offline` (9b) maps each resource and data source type
  to its AWS service and fails when one has no emulator endpoint, or
  when a type has no mapping. Before 4d, that check was promised by a
  comment in `scripts/terraform/emulator.sh` but did not exist.
  Measured: the first emulator apply of this root sent its Identity
  Center calls to the real endpoint, which refused the emulator's fake
  credentials. Nothing was created.

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
- **4b: Dex in front of Keycloak.** Rejected, as in ADR-0005: one
  connector needs no broker, and Dex would be one more pod to pin and
  run.
- **4b: `policy.default: role:readonly`.** Rejected: every signed-in
  user, even one with no group, would read every Application.
- **4b: developers scoped by AppProject.** Rejected for now: all
  Applications share project `platform`, and one project per
  environment would change the generated Applications and their
  promotion. Name patterns give the same boundary, and
  `check-argocd-rbac` keeps each pattern on its own environment.
- **4b: break-glass by deleting the admin password, or a second local
  account.** Rejected: both are harder to undo under pressure than a
  flag, and a second account is one more standing credential.
- **4c: everyone signed in gets Viewer** (the Phase 4 plan). Rejected:
  a user with no group would read every dashboard and log, while Argo
  CD gives the same user nothing.
- **4c: Grafana's JWT auth with the Keycloak token.** Rejected: it adds
  a second login path to test and secure. The live test runs the real
  redirect flow with curl instead.
- **4d: AWS's TEAM solution for elevation** (the Phase 4 plan's other
  option for D-5). Rejected: it is a deployed application with its own
  approval flow, it cannot be tested offline, and it adds a standing
  service to a project that runs nothing in AWS.
- **4d: PowerUserAccess for developers in their account.** Rejected:
  developers change their environment through Git and Argo CD, so
  standing write access in the console would bypass review.
- **4d: looking up the instance and groups with data sources.**
  Rejected: data sources call AWS during plan, and
  `check-terraform-offline` allows none outside its narrow list.
- **4b: an alert from Prometheus on the admin flag.** Not possible
  without kube-state-metrics on the hub, which no other need justifies.
  The flag's alert is posted to Alertmanager directly; the use of the
  admin is alerted from Prometheus.

## Consequences

- 4b configured Argo CD against the running IdP; 4c does the same for
  Grafana.
- People sign in to Argo CD through Keycloak and get their group's role.
  The local admin is no longer a standing path.
- `make idp-install` must run again after Argo CD is (re)installed, so
  the Secret `argocd-oidc` exists. `make argocd-test-sso` checks it.
- The `argocd` namespace may hold `argocd-oidc`; `make argocd-uninstall`
  accepts it in its namespace inventory.
- 4d: changing who has AWS access, standing or elevated, is a reviewed
  pull request. An expired elevation blocks CI until it is removed.
  Applying any of it is for a real deployment (6.4b or later); nothing
  here has been applied.
- 4c: people sign in to Grafana through Keycloak. After `make
  obs-install` on a fresh hub, `make idp-install` must run again to
  write `obs-grafana-oidc`; `make obs-uninstall` removes it.
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
- 4b: no Argo CD credential is in Git. The client secret is a Secret
  reference, and the admin password stays in
  `argocd-initial-admin-secret`, never printed. Turning the admin off
  ends its sessions at once. The password is not rotated after a
  break-glass; the runbook says how to do it by hand.
- 4d: no standing admin, developer or break-glass access in prod;
  every elevation is reviewed, bounded to 8 hours and visible in Git.
  Sessions are one hour (four for ReadOnly). Identity Center has no
  charge.
- 4c: Grafana's client secret reaches the pod only through its
  environment, from a Secret; the values and the Helm release hold none.
  A user without a mapped group cannot sign in.

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
- 4b: `make check-argocd-rbac`, in `make validate`, checks:
  - the admin and anonymous access are off, and there is no other local
    account;
  - the OIDC issuer and client, the secret by reference only, and a
    callback the realm allows;
  - no default role, roles from `groups`;
  - every realm group mapped to exactly its role, only platform-admins
    as admin, no redefined built-in role, and developer grants limited
    to get/sync/logs on their own environment.

  `make check-argocd-rbac-regression` adds 18 mutation cases.
- 4b, live on the hub:
  - `make argocd-test-sso`: one Keycloak token per test user against the
    Argo CD API, with list, get and dry-run sync. It proves the table
    above, plus a forged token 401 and the admin login 401.
  - `make argocd-test-breakglass`: off, login 401; on, login 200, the
    token works, `ArgoCDBreakGlassActive` active, status passes, and an
    expiry in the past makes status fail; the login raises
    `ArgoCDLocalAdminLogin`; off, the earlier token 401, login 401, the
    alert resolved.
  - The rule files have promtool unit tests, and `make obs-status`
    checks the API server is scraped.
- 4c: `make check-grafana-sso`, in `make validate`, checks on the
  generated values:
  - anonymous off, generic OAuth on with the realm's `grafana` client
    and PKCE, and the three URLs on the lab issuer;
  - no client secret in the values, only the optional Secret that
    `idp-install` writes;
  - a callback the realm allows;
  - the role expression built from the realm's groups, strict, no
    server admin, role sync on.

  `make check-grafana-sso-regression` adds 13 mutation cases.
- 4c, live on the hub: `make obs-test-sso` runs Grafana → Keycloak login
  form → Grafana callback with curl for each test user:
  - admin-user is Admin with `datasources:write`;
  - auditor-user, dev-user and uat-user are Viewers without it;
  - nogroup-user is refused with no session;
  - with no session the API answers 401;
  - the local admin still signs in, and that sign-in raises
    `GrafanaLocalAdminLogin` in Alertmanager.

  `grafana.rules.yml` has a promtool unit test.
- 4d, offline:
  - `terraform test` in `identity-center` (14 runs): the permission
    sets, their policies and sessions, the twelve standing assignments
    with prod ReadOnly only, and each elevation rule accepted or
    refused;
  - `terraform test` in `eks` (31 runs, 5 new): the two view entries,
    their scopes, none by default, no developer in prod, no ARN with a
    path;
  - `make check-elevations` and 12 regression cases with a fixed clock;
  - `check-terraform-offline` 9b and 3 new regression cases (endpoint
    present, endpoint missing, unmapped type);
  - the emulator coverage row for `identity-center`: plan ok; apply and
    destroy blocked by the emulator lacking SSO Admin
    ListTagsForResource.
