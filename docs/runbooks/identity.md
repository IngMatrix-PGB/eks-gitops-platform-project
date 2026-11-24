# Runbook: The lab identity provider (Keycloak)

Keycloak runs on the lab-multicluster hub as the local lab's identity
provider ([ADR-0025](../adr/0025-lab-identity-provider.md)). It is for
the lab only. Every command runs from the repository root, with the lab
up (`make mc-up`).

## Install and check

```bash
LAB_CLUSTER=hub make idp-install
LAB_CLUSTER=hub make idp-status
```

`idp-install` is idempotent:

- **First run:** it generates the bootstrap admin password, the client
  secrets and the test users' passwords into two Secrets in namespace
  `keycloak`.
- **Later runs:** it keeps those Secrets, and restarts Keycloak only
  when the realm file, the image or the manifest changed.
- **Passwords:** each test user's password is copied to
  `.local/identity/<user>` (mode 600).

`idp-status` changes nothing. It checks the issuer from inside the
cluster and gets one token per test user, through a port-forward on
`127.0.0.1:18080`.

## Test users

| User | Group | Role |
|---|---|---|
| `admin-user` | platform-admins | platform administrator |
| `dev-user` | developers-dev | developer, dev only |
| `uat-user` | developers-uat | developer, uat only |
| `auditor-user` | auditors | read-only |
| `nogroup-user` | none | signed in, no role |

The password of a user is in `.local/identity/<user>`. Do not paste it
anywhere.

## Browser access (optional)

The issuer is the in-cluster name
`keycloak.keycloak.svc.cluster.local`, so tokens are the same for every
caller. For a browser on this machine to use it:

1. Add one line to `/etc/hosts` yourself:
   `127.0.0.1 keycloak.keycloak.svc.cluster.local`.
2. Forward the port:

   ```bash
   .tools/bin/kubectl --kubeconfig .local/kubeconfig-hub -n keycloak \
     port-forward service/keycloak 8080:8080
   ```

3. Open `http://keycloak.keycloak.svc.cluster.local:8080/realms/platform/account`
   and sign in as a test user.

The Keycloak admin console is at `/admin/`. Its user name and password
are in the Secret `keycloak-bootstrap-admin`. Use it only to look
around: the realm comes from Git and a restart re-imports it.

## Restart, rotation, removal

- **Restart:** delete the pod. The new pod re-imports the realm with the
  same secrets, and `idp-status` passes again.
- **Rotate everything:** delete the Secrets `keycloak-realm-secrets` and
  `keycloak-bootstrap-admin`, run `make idp-install`, then restart the
  pod.
- **Remove:** `LAB_CLUSTER=hub make idp-uninstall CONFIRM=yes` deletes
  the namespace and `.local/identity/`.

## Troubleshooting

- **The install refuses for memory.** Keycloak needs about 0.75 GiB.
  Free some (for example `make obs-uninstall` on a spoke), or set
  `IDP_SKIP_MEMORY_CHECK=1` on purpose.
- **The pod never gets Ready.** Run
  `.tools/bin/kubectl --kubeconfig .local/kubeconfig-hub -n keycloak logs deploy/keycloak`.
  If a realm import error mentions a placeholder, a key is missing from
  `keycloak-realm-secrets`: run `make idp-install` again.
