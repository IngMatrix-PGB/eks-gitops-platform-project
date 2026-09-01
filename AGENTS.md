# AGENTS.md

Operating rules for anyone — human or AI agent — making changes in this
repository. These rules apply regardless of tooling and take precedence
over convenience.

## Phased delivery discipline

This project is built in small, reviewable phases — see the "Delivery
Roadmap" section of
[`docs/architecture/technical-architecture.md`](docs/architecture/technical-architecture.md)
for the current phase list and status. Do not collapse multiple phases
into one change. When in doubt about whether something belongs in the
current phase, it does not — raise it under the TAD's "Risks and Open
Questions" instead.

## Safety gates that are never implicitly authorized

Before any action that changes AWS, a non-disposable Kubernetes cluster,
version-control-platform settings, remote branches, secrets, or any other
external system:

1. State the exact intended command or mutation.
2. State the target account, region, cluster, repository, and
   environment.
3. State the cost and destructive risk.
4. Request fresh, explicit authorization for that specific action.
5. Stop if authorization is absent or ambiguous.

The following are never implicitly authorized by a prior approval:

- `terraform apply` or `terraform destroy`.
- Creating EKS, VPC, NAT Gateway, or load-balancer resources.
- `kubectl apply`, `patch`, or `delete` against a non-disposable cluster.
- Creating or modifying branch protection, environments, secrets, or
  repository settings on any Git hosting platform.
- Configuring a remote, pushing, opening a pull request, or cutting a
  release.

Read-only discovery and local validation are always allowed within the
current task's scope.

## Confidentiality

Any reference material that is local-only and not meant to be shared
must never be added to version control:

- Exclude it using a local, non-versioned Git exclude mechanism only
  (`.git/info/exclude`) — never a versioned ignore file.
- Never let its directory or file names appear in any committed file,
  including code comments, scripts, documentation, or commit messages.
- Never copy a proprietary excerpt, internal identifier (account ID,
  internal domain, internal repository or cluster name, commit SHA),
  local machine path, or original diagram/screenshot into a versioned
  file.
- **No versioned file may claim that a decision in this project was
  informed by reviewing a specific external system, a prior
  organization, or a private document.** Architectural reasoning stands
  on this project's own requirements and on general, well-documented
  engineering risks — never on an implied or stated external source,
  regardless of whether such material was ever actually used.
- `scripts/validate/check-private-untracked.sh` (part of
  `make validate`) enforces the exclusion rule and never prints the
  excluded path, pattern, or file name, even when it fails.

## The TAD is the source of truth

[`docs/architecture/technical-architecture.md`](docs/architecture/technical-architecture.md)
is the single, authoritative architecture document — it absorbs
evidence/status, risks, and the roadmap; this repository does not
maintain those as separate files. **Update the TAD and the relevant ADR
in `docs/adr/` in the same change that changes the architecture they
describe** — documentation drift is treated as a defect, not a
follow-up. Use these confidence labels consistently, and never upgrade a
claim to `VERIFIED` without an automated test or reproducible runtime
evidence:

- `VERIFIED` — exercised by an automated test or runtime evidence.
- `CODE-CONFIRMED` — directly proven by code/configuration, not runtime
  tested.
- `PROPOSED` — a design decision made but not yet implemented.
- `NOT IMPLEMENTED` — deliberately absent so far.
- `OUT OF SCOPE` — intentionally excluded from the current design.
- `UNKNOWN` — genuinely undetermined; do not guess.

## Validation

```bash
make help      # list all available targets
make validate  # run every documentation validation check
```

Run `make validate` before proposing any change, and resolve every
failure before staging anything.

## Committing changes

Do not stage or commit changes unless explicitly asked to in the current
task. When asked to commit, run `make validate` first and resolve any
failure before proposing a commit. Do not push, open a pull request, or
configure a remote without a separate, explicit authorization (see
"Safety gates" above).
