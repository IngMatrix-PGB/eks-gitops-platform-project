# Runbook: Signing in to Argo CD, roles and break-glass

People sign in to the hub's Argo CD through the lab's Keycloak and get
the role of their group
([ADR-0025](../adr/0025-lab-identity-provider.md)). The local `admin` is
off; it is break-glass only. Every command runs from the repository
root, with the lab up (`make mc-up`) and Keycloak installed
([identity](identity.md)).

## Set up after an install

```bash
LAB_CLUSTER=hub make idp-install
LAB_CLUSTER=hub make argocd-test-sso
```

`idp-install` writes Argo CD's client secret to the Secret
`argocd/argocd-oidc`. Run it again whenever Argo CD was installed after
Keycloak, for example after `make mc-up` or a hub restore.
`argocd-test-sso` changes nothing. It gets a token per test user and
checks the role matrix on the Argo CD API.

## Roles

| Group | Role | Can |
|---|---|---|
| platform-admins | admin | everything |
| auditors | readonly | read every Application, no sync |
| developers-dev | developer-dev | get, sync and read logs of `platform-*-dev` |
| developers-uat | developer-uat | the same for `platform-*-uat` |
| none | none | sign in, see nothing |

The roles are in `configs.rbac` of `lab/argocd/values-lab.yaml`.
`make check-argocd-rbac` checks them offline. A change reaches the hub
through [argocd-upgrade](argocd-upgrade.md).

## Signing in with a browser

1. Follow "Browser access" in [identity](identity.md): the `/etc/hosts`
   line and the Keycloak port-forward.
2. In a second terminal: `LAB_CLUSTER=hub make argocd-port-forward`.
3. Open `https://localhost:8443`, choose **Log in via Keycloak** and use
   a test user. Its password is in `.local/identity/<user>`.

## Break-glass

Use it only when SSO is broken and something must be done in Argo CD
that kubectl cannot do.

```bash
LAB_CLUSTER=hub make argocd-breakglass CONFIRM=yes REASON="what is broken and why" HOURS=1
```

- `HOURS` is 1 to 8 (default 1).
- It records who, why and until when on the ConfigMap `argocd-cm`, and
  raises `ArgoCDBreakGlassActive` in the hub's Alertmanager until then.
- Sign in as `admin`. The password is in the Secret
  `argocd/argocd-initial-admin-secret`, key `password`. Read it in your
  own terminal; do not paste it anywhere.
- Every admin login raises `ArgoCDLocalAdminLogin`.

When you are done:

```bash
LAB_CLUSTER=hub make argocd-breakglass-off
LAB_CLUSTER=hub make argocd-breakglass-status
```

Turning it off ends every admin session at once and resolves the alert.
The next `make argocd-upgrade` would turn it off too.
`argocd-breakglass-status` fails while the admin is on past its expiry,
or on with no record (someone turned it on by hand).

To test the whole cycle (on, login, alerts, off) on the hub:
`LAB_CLUSTER=hub make argocd-test-breakglass`. It always turns the
admin off again, also when it fails.

### Rotating the admin password after a break-glass

The admin password is not rotated automatically. To rotate it, with the
admin on: sign in, use **User Info → Update Password** in the UI, then
store the new password where your team keeps break-glass credentials,
and turn break-glass off.

## Troubleshooting

- **"Log in via Keycloak" fails with an OIDC error:** the Secret
  `argocd-oidc` is missing or stale. Run `LAB_CLUSTER=hub make
  idp-install`, then `make argocd-test-sso`.
- **A user sees no Application:** check the user's group in the token
  (`make idp-status` prints each test user's groups) and the mapping in
  `policy.csv`.
- **The break-glass alert was not sent:** the command prints a warning
  when Alertmanager is absent or down; break-glass still works. Check
  `LAB_CLUSTER=hub make obs-status`.
- **lab-lite or the EKS session:** these have no Keycloak, so SSO login
  fails there. On lab-lite, use kubectl or break-glass
  (`LAB_CLUSTER=lab-lite`, the default). The EKS session is reached
  through kubectl only (its own kubeconfig) until 4e decides the AWS
  identity provider.
