# Runbook: The sandbox AWS session (Phase 6.4b)

This runbook brings up the hub and the dev spoke in one sandbox AWS
account, collects the evidence, and destroys everything again
([ADR-0024](../adr/0024-sandbox-aws-session.md)). It creates real
resources that cost money: run it only with an explicit go for this
session. Keep resources alive for 3 hours or less.

Every command runs from the repository root. Every target refuses to
run without `AWS_PROFILE` set to the sandbox profile, and none of them
runs in CI.

## Prerequisites

- **A sandbox account of your own.** Never a work account, and never
  the `default` profile: on the maintainer's machine, `default` is an
  unrelated account.
- **A named profile for that account,** for example through IAM
  Identity Center. Sign in first:
  `aws sso login --profile <sandbox-profile>`.
- **Tools and charts:** `make tools-install`, `make charts-fetch`, and
  the `aws` CLI v2.
- **Inputs, all under `.local/eks-sandbox/`** (gitignored; make every
  file mode 600):

  | File | Content |
  |---|---|
  | `allowed-accounts` | The sandbox account ID, one per line. Any other account is refused |
  | `session.env` | The template below, filled in |
  | `dev-backend-value` | A synthetic value for the dev secret, e.g. `openssl rand -hex 16 > .local/eks-sandbox/dev-backend-value` |

`session.env` (`KEY=value`, no quotes, never sourced):

```text
SESSION_ID=6-4b-1
SESSION_REGION=us-east-1
SESSION_OWNER=<github-handle>
SESSION_OPERATOR_CIDR=<your public IPv4>/32
SESSION_ADMIN_PRINCIPAL_ARN=<the IAM role you sign in with>
SESSION_BREAKGLASS_PRINCIPAL_ARN=<a second role, for break-glass>
SESSION_BUDGET_USD=20
SESSION_BUDGET_EMAIL=<where budget alerts go>
SESSION_ADDON_POD_IDENTITY=<from preflight>
SESSION_ADDON_VPC_CNI=<from preflight>
SESSION_ADDON_COREDNS=<from preflight>
SESSION_ADDON_KUBE_PROXY=<from preflight>
SESSION_ADDON_METRICS_SERVER=<from preflight>
```

The principal ARNs are IAM role ARNs (`arn:aws:iam::<account>:role/...`),
not the `assumed-role` ARN that STS prints for an SSO session.

## Session

```bash
export AWS_PROFILE=<sandbox-profile>
```

1. **Preflight** (read-only). It checks:
   - the identity, against the allowlist;
   - that no EKS cluster is left from before.

   It also prints the current add-on versions, to copy into
   `session.env`.

   ```bash
   make eks-session-preflight
   ```

2. **Apply, one stack at a time, in this order:**
   1. `budget`
   2. `network-platform`
   3. `eks-platform`
   4. `network-dev`
   5. `eks-dev`
   6. `identity-dev`

   For each stack, plan, read the counts and the log, then apply:

   ```bash
   make eks-session-plan STACK=budget
   make eks-session-apply STACK=budget CONFIRM=yes
   ```

   An apply refuses when:
   - the previous stack is not applied;
   - there is no saved plan;
   - the code or the inputs changed since the plan.

   The two EKS stacks take about 15 minutes each.

3. **Kubeconfigs:** `make eks-session-kubeconfig` writes
   `.local/kubeconfig-eks-hub` and `.local/kubeconfig-eks-dev`.

4. **In-cluster setup:** `make eks-session-hub`. In order, it sets up:
   - **on the spoke:**
     - namespace `dev` (PSA restricted);
     - the Role and RoleBinding that Argo CD's access entry maps to;
     - ESO;
   - **the synthetic value** of the dev secret;
   - **on the hub:**
     - Argo CD;
     - the spoke's cluster Secret (`awsAuthConfig`, no token);
     - the aws-eks root Application.

5. **Evidence:** `make eks-session-verify`. It waits for
   `platform-smoke-dev` to be Synced/Healthy, then checks:
   - the ExternalSecret is Ready, and its SecretStore has no `auth`
     block (so it reads through Pod Identity);
   - `/api/info` answers through a port-forward.

   It writes `.local/eks-sandbox/evidence/verify-<time>.txt`.

6. **Teardown** (start right after the evidence):

   ```bash
   make eks-session-teardown
   make eks-session-destroy STACK=identity-dev CONFIRM=yes
   make eks-session-destroy STACK=eks-dev CONFIRM=yes
   make eks-session-destroy STACK=network-dev CONFIRM=yes
   make eks-session-destroy STACK=eks-platform CONFIRM=yes
   make eks-session-destroy STACK=network-platform CONFIRM=yes
   make eks-session-sweep
   ```

   The session is over only when `make eks-session-sweep` passes.
   - What it allows to remain: KMS keys pending deletion, secrets
     scheduled for deletion, and the budget, which is free and still
     alerts on trailing costs.
   - Removing the budget too: once the bill is recorded, run
     `make eks-session-destroy STACK=budget CONFIRM=yes`.

7. **Bill, 24–48 hours later:** in Cost Explorer, filter by the
   `Session` tag and the day. Record the measured cost in the TAD,
   replacing the `INFERRED` estimate.

## Aborting

At any point, skip ahead to step 6. Destroy refuses to go out of order:
destroy the last stack that has resources first.

If a VPC does not delete, the sweep names what still holds it, usually
an ENI or a load balancer that a Kubernetes object created. Delete that
first, then destroy again.

## What can never happen through these targets

- **Running against the `default` profile or an account not on the
  allowlist:** the account is checked before any command runs, and the
  provider is pinned to it.
- **Applying without `CONFIRM=yes`, or a plan nobody looked at:** apply
  takes only a saved plan whose inputs are unchanged.
- **Running from CI:** the script refuses CI, and check 9f of
  `check-terraform-offline` fails if a workflow calls it.
- **Committing an account ID, an e-mail or a state file:** all of them
  stay under `.local/`.
