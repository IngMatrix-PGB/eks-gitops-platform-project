# ADR-0026: One AppProject per environment

**Status:** Accepted
**Date:** 2026-11-27

## Context

Every generated Application was in one AppProject, `platform`, whose
destinations were the dev, uat and prod spokes. Measured on the lab hub
on 2026-11-27: six Applications (smoke, notes and postgres in dev and
uat), all in `platform`; developer access in `argocd-rbac-cm` as name
patterns, `platform/platform-*-dev` and `platform/platform-*-uat`.

Two problems follow:

- **The boundary is a naming convention.** A developer role reaches an
  Application because of its name. The project would accept an
  Application of any name aimed at any environment, so the boundary
  holds only while every name follows the pattern and lands where its
  name says. `check-argocd-rbac` checks the patterns, not where the
  Applications deploy.
- **The lab cannot prove the AWS shape.** ADR-0025 (4e) decided that
  Argo CD in AWS is the EKS Argo CD capability. The capability scopes a
  group to an AppProject (a project role listing group IDs), not to a
  name pattern, so it needs one AppProject per environment. 4b had
  rejected that for the lab, because all Applications shared
  `platform`.

## Decision

- **One AppProject per environment, `platform-<env>`,** rendered for
  every profile from the same template. Each has the one source
  repository, exactly one destination (its own spoke and namespace on
  `local-multicluster` and `aws-eks`; its own in-cluster namespace on
  `local-kind`) and the same kind whitelists as every other project.
  The whitelists are written once in the template.
- **Each generated Application is in its environment's project**
  (`project: platform-{{env}}` in every ApplicationSet). Application
  names do not change, so nothing is deleted or recreated; only
  `spec.project` changes.
- **Developers get access through a project role,** the shape the EKS
  capability uses. On the lab hub, `platform-<env>` has the role
  `developer` whose only group is `developers-<env>`, with get and sync
  on applications and get on logs, all on `platform-<env>/*`. The
  groups come from `multicluster.developerGroups` in
  `gitops/bootstrap/values.yaml`; prod has none. `argocd-rbac-cm` keeps
  only the global mappings: platform-admins to `role:admin`, auditors
  to `role:readonly`, and no policy line.
- **`platform` stays, unchanged and unused, for one release.** A switch
  back to a revision whose Applications still name it then never leaves
  them without their project. A later change removes it, once no
  Application uses it.

## Alternatives Considered

- **Keep the name patterns.** Rejected: the boundary stays a naming
  convention, and the lab keeps a shape the AWS target cannot use.
- **Project per environment, developer policies still in
  `argocd-rbac-cm` (`platform-<env>/*`).** Rejected: it fixes the
  destination boundary but not the second problem; the capability has
  no global policy file to put them in.
- **Rename the Applications or the ApplicationSets.** Rejected: a new
  name deletes and recreates the Application and everything it
  manages, data store volumes included.
- **Remove `platform` in the same change.** Rejected: pruning it while
  an Application still names it, during a switch or its rollback,
  leaves that Application with no project until the ApplicationSet
  catches up.

## Consequences

- Moving an Application to another environment means moving it to
  another project, which its destination already forces.
- A new environment needs its project, which the template adds with the
  environment, and its developer group in `developerGroups`.
- The aws-eks render has the projects but no roles. Its roles list
  Identity Center group IDs, set at the first deployment (ADR-0025, 4e).
- Amends ADR-0025: the 4b alternative "developers scoped by AppProject"
  is now the lab's design, and 4e's "the generated Applications move to
  one AppProject per environment" is done in the lab.
- `platform` is removed in a follow-up change.

## Security and Cost Implications

- Security: the environment boundary moves from a name pattern to the
  project's destination, which Argo CD enforces when an Application is
  created and on every sync. A developer role cannot reach another
  environment's Applications, and no Application in `platform-dev` can
  deploy outside dev, whoever creates it. Grants stay the same: get and
  sync on applications and get on logs, no delete, no wildcard, no
  deny, no default role. Until it is removed, `platform` still allows
  every environment; only admins can create an Application, and none is
  in it.
- Cost: none. AppProjects are Kubernetes objects in the hub; the EKS
  capability charges per Application, not per project.

## Validation Method

- `make gitops-render`: for each profile, the AppProjects are exactly
  `platform` and `platform-<env>`; each `platform-<env>` has one
  destination, its own environment; source and kinds are the same
  everywhere; roles only on the lab hub; every ApplicationSet names
  `platform-<env>`. A self-test proves that an Application back on
  `platform` and a second destination in `platform-dev` are refused.
- `make check-argocd-rbac`: `policy.csv` has only the two global
  mappings and no policy line; each realm group `developers-<env>` is
  the only group of the `developer` role of `platform-<env>`, with
  exactly the three grants on its own project; no project has a role
  without its realm group. 21 mutation cases
  (`check-argocd-rbac-regression`).
- `make argocd-test-sso` (live): the role matrix of 4b is unchanged
  (developers-dev syncs dev, 403 on uat and on the root; auditors read,
  403 on sync; no group sees nothing); every Application is in its
  environment's project; an Application in `platform-dev` aimed at
  `spoke-uat` is refused at create, even for an admin.
