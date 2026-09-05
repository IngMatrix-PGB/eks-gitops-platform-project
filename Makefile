.DEFAULT_GOAL := help

.PHONY: help validate check-markdown check-links check-adr check-secrets check-forbidden-terms check-forbidden-terms-regression check-tad check-private-untracked \
	check-standard-workload-chart check-tool-platforms-regression \
	tools-check tools-install lab-create lab-status lab-destroy lab-test lab-test-lifecycle \
	argocd-chart-fetch argocd-render argocd-install argocd-status argocd-uninstall argocd-port-forward \
	argocd-test-runtime-health argocd-test-lifecycle \
	gitops-repo-setup gitops-repo-check gitops-repo-remove gitops-render gitops-bootstrap \
	gitops-status gitops-test gitops-uninstall gitops-test-lifecycle \
	gitops-switch-revision gitops-retire-appproject-kind gitops-resume-appproject-kind \
	gitops-test-revision-switch gitops-test-appproject-kind-retirement \
	eso-chart-fetch eso-render check-eso-chart eso-install eso-status eso-uninstall \
	eso-test-runtime-health eso-test-lifecycle \
	eso-provision-source-secret eso-test-secret-lifecycle eso-test-provision-source-secret-idempotency \
	terraform-fmt terraform-init terraform-validate terraform-test terraform-validate-offline

help: ## Show this help
	@echo "eks-gitops-platform-project - available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

validate: check-markdown check-links check-adr check-secrets check-forbidden-terms check-forbidden-terms-regression check-tad check-private-untracked check-standard-workload-chart check-tool-platforms-regression ## Run every Phase 1 documentation validation check plus the standard-workload chart contract

check-markdown: ## Basic Markdown formatting checks on every versionable .md file
	@bash scripts/validate/check-markdown-basic.sh

check-links: ## Verify local Markdown links resolve to existing files
	@bash scripts/validate/check-links.sh

check-adr: ## Verify ADR files use recognized statuses and required sections
	@bash scripts/validate/check-adr-structure.sh

check-secrets: ## Scan versionable files for secret-shaped patterns
	@bash scripts/validate/check-secrets.sh

check-forbidden-terms: ## Scan versionable files for confidentiality-restricted terms
	@bash scripts/validate/check-forbidden-terms.sh

check-forbidden-terms-regression: ## Regression-test the forbidden-terms validator's narrow GitHub Actions SHA-pin exception
	@bash tests/validate/test-forbidden-terms.sh

check-tad: ## Verify the Technical Architecture Document has all required sections
	@bash scripts/validate/check-tad-sections.sh

check-private-untracked: ## Verify local-only reference material is excluded and untracked
	@bash scripts/validate/check-private-untracked.sh

check-standard-workload-chart: ## Offline lint/render/schema/PSS/dry-run validation of charts/standard-workload for both environments
	@sh scripts/validate/check-standard-workload-chart.sh

check-tool-platforms-regression: ## Regression-test the darwin-arm64/linux-amd64 platform support in install-tools.sh and check-prerequisites.sh
	@sh tests/lab/test-tool-platforms.sh

tools-check: ## Verify the project-local kind/kubectl are installed and match pinned checksums (read-only)
	@sh scripts/lab/check-prerequisites.sh

tools-install: ## Download and verify the pinned project-local kind/kubectl into .tools/bin/ (mutates .tools/ only)
	@sh scripts/lab/install-tools.sh

lab-create: ## Create the project-local kind cluster if absent; no-op if it already matches the pinned baseline
	@sh lab/kind/create.sh

lab-status: ## Report project-local kind cluster health and identity (read-only)
	@sh lab/kind/status.sh

lab-destroy: ## Destroy only the exact project-local kind cluster; no-op if it does not exist
	@sh lab/kind/destroy.sh

lab-test: ## Read-only shape/identity checks against the existing project cluster
	@sh tests/lab/test-cluster-shape.sh

lab-test-lifecycle: ## Mutating: proves create/destroy idempotency end-to-end (cluster must be absent first)
	@sh tests/lab/test-idempotency.sh

argocd-chart-fetch: ## Download and checksum-verify the pinned Argo CD chart into .tools/charts/ (the only target allowed to fetch it)
	@sh lab/argocd/chart-fetch.sh

argocd-render: ## Fully offline Helm render of the pinned chart/values; proves every image is approved and digest-pinned
	@sh lab/argocd/render.sh

argocd-install: ## Fail-closed idempotent install: absent->install, exact match->no-op, any drift->fail closed
	@sh lab/argocd/install.sh

argocd-status: ## Report Argo CD release/workload/CRD status (read-only)
	@sh lab/argocd/status.sh

argocd-uninstall: ## Uninstall the Argo CD release; CRDs retained; namespace deleted only if owned and inventory-clean
	@sh lab/argocd/uninstall.sh

argocd-port-forward: ## Foreground port-forward to the Argo CD server UI/API at https://localhost:8443
	@sh lab/argocd/port-forward.sh

argocd-test-runtime-health: ## Read-only runtime health checks against an installed Argo CD release
	@sh tests/argocd/test-runtime-health.sh

argocd-test-lifecycle: ## Mutating: proves install/no-op/uninstall idempotency and CRD retention end-to-end
	@sh tests/argocd/test-idempotency.sh

# --- Phase 2.3: private repository GitOps bootstrap ---
# Network effects: gitops-repo-setup contacts api.github.com (reads/adds
#   exactly one deploy key) and reads the argocd-ssh-known-hosts-cm
#   ConfigMap; gitops-bootstrap/-test-lifecycle contact GitHub over SSH
#   (git ls-remote only, via the project's own deploy key). No other
#   target performs any network access.
# Filesystem effects: gitops-repo-setup writes .local/gitops/github-
#   deploy-key(.pub) only if absent (mode 600, never overwritten);
#   gitops-bootstrap may write a temporary rendered root manifest under
#   .local/gitops/ for a non-"main" REVISION. gitops-repo-remove deletes
#   those same two key files. No other target writes to disk.
# GitHub mutation: only gitops-repo-setup (adds a read-only deploy key,
#   only if absent) and gitops-repo-remove (deletes it) ever mutate
#   GitHub. gitops-repo-check is the read-only equivalent of
#   gitops-repo-setup - it inspects and reports, it never adds/removes
#   anything.
# Cluster mutation: gitops-repo-setup creates the Argo CD repository
#   Secret (only if absent); gitops-bootstrap applies the root
#   Application (only if absent, fails closed on drift); gitops-uninstall
#   deletes the root Application/its cascade/owned namespaces only
#   (never Argo CD, its CRDs, the repository Secret, or the deploy key);
#   gitops-test-lifecycle performs all of the above plus a deliberate,
#   self-healed ConfigMap drift. gitops-render, gitops-status, and
#   gitops-test never mutate the cluster.
# Preconditions: the project kind cluster and Argo CD must already be
#   installed and healthy (`make lab-create argocd-install`) for every
#   target except gitops-render (fully offline).
# Idempotency: gitops-repo-setup, gitops-bootstrap, and gitops-uninstall
#   are all safe to run repeatedly - each is a true no-op once its goal
#   state is already met. No target here implicitly deletes the deploy
#   key; only gitops-repo-remove does, and only with CONFIRM=REMOVE.

gitops-repo-setup: ## Idempotently provision the deploy key, GitHub deploy key, and Argo CD repository Secret (mutates GitHub + cluster + .local/gitops/)
	@sh lab/gitops/repo-setup.sh

gitops-repo-check: ## Read-only inspection of the same repository-authentication state (no mutation)
	@GITOPS_CHECK_ONLY=1 sh lab/gitops/repo-setup.sh

gitops-repo-remove: ## Remove the repository Secret, GitHub deploy key, and local key files (requires CONFIRM=REMOVE; never run by the lifecycle test)
	@sh lab/gitops/repo-remove.sh

gitops-render: ## Fully offline Helm render of gitops/bootstrap; proves exactly 1 AppProject/1 ApplicationSet/2 generators/0 Secrets/no wildcards (accepts REVISION=<value>)
	@sh lab/gitops/render.sh

gitops-bootstrap: ## Fail-closed idempotent apply of the root Application only (accepts REVISION=<value>, default main)
	@sh lab/gitops/bootstrap.sh

gitops-status: ## Report root Application/AppProject/ApplicationSet/generated Applications/ConfigMaps status (read-only)
	@sh lab/gitops/status.sh

gitops-test: ## Read-only runtime health checks against an already-bootstrapped Phase 2.3 state
	@sh tests/gitops/test-runtime-health.sh

gitops-uninstall: ## Two-phase transactional uninstall (Phase 2.6.3a): read-only preflight classification of staging/production, zero mutation on any unclassifiable object; then deletes the root Application (foreground cascade) and only namespaces Phase A cleared; retains a namespace an active ESO scoped release still targets; preserves Argo CD/CRDs/repo Secret/deploy key
	@sh lab/gitops/uninstall.sh

gitops-switch-revision: ## Phase 2.6.3a: safely switch the root Application's targetRevision in place (patch, never delete+recreate); preserves UID/finalizers; requires 3 stable reads; rolls back automatically on failure (REVISION=<value>)
	@sh lab/gitops/switch-revision.sh

gitops-retire-appproject-kind: ## Phase 2.6.3a: drain SecretStore/ExternalSecret from one environment before narrowing the AppProject whitelist (ENV=staging|production ACTION=--drain)
	@sh lab/gitops/retire-appproject-kind.sh $(ENV) $(ACTION)

gitops-resume-appproject-kind: ## Phase 2.6.3a: resume automated sync after retire-appproject-kind's drain + the whitelist-narrowing Git change have both landed (ENV=staging|production)
	@sh lab/gitops/retire-appproject-kind.sh $(ENV) --resume

gitops-test-lifecycle: ## Mutating: proves bootstrap/no-op/self-heal/isolation/uninstall/no-op end-to-end (requires REVISION=<pushed branch>)
	@sh tests/gitops/test-lifecycle.sh

gitops-test-revision-switch: ## Phase 2.6.3a: mutating, proves switch-revision.sh converges/rolls-back correctly (requires REVISION=<pushed branch>)
	@sh tests/gitops/test-revision-switch.sh

gitops-test-appproject-kind-retirement: ## Phase 2.6.3a: mutating, proves the 8-step SecretStore/ExternalSecret drain/resume sequence end-to-end
	@sh tests/gitops/test-appproject-kind-retirement.sh

eso-chart-fetch: ## Download and checksum-verify the pinned External Secrets Operator chart (only target allowed to fetch it)
	@sh lab/eso/chart-fetch.sh

eso-render: ## Fully offline render + collision/ownership proof for the decoupled CRD set and both scoped controller releases
	@sh lab/eso/render.sh

check-eso-chart: ## Offline lint + collision/ownership proof for the ESO chart (standalone - requires a network chart fetch, so not part of `make validate`)
	@sh scripts/validate/check-eso-chart.sh

eso-install: ## Fail-closed idempotent install: 25 CRDs (kubectl apply, no Helm ownership) + two scoped Helm releases
	@sh lab/eso/install.sh

eso-status: ## Report CRD/release/Deployment health for both scoped releases (read-only)
	@sh lab/eso/status.sh

eso-uninstall: ## Uninstall both scoped releases (production then staging; accepts ENV=staging|production for one at a time); never touches the 25 CRDs; refuses to uninstall staging while production still exists
	@sh lab/eso/uninstall.sh $(ENV)

eso-test-runtime-health: ## Read-only runtime health checks against an already-installed ESO bootstrap
	@sh tests/eso/test-runtime-health.sh

eso-test-lifecycle: ## Mutating: proves install/no-op/uninstall(CRDs retained)/no-op/restore end-to-end
	@sh tests/eso/test-idempotency.sh

eso-provision-source-secret: ## Phase 2.6.2: create/rotate (default) or delete (ACTION=--delete) the imperative, out-of-Git source Secret for ENV=staging|production; value is read from stdin or an echo-disabled prompt, never a CLI argument
	@sh lab/eso/provision-source-secret.sh $(ENV) $(ACTION)

eso-test-secret-lifecycle: ## Phase 2.6.2: mutating end-to-end proof of the SecretStore/ExternalSecret contract (provision/reconcile/mount/rotate/propagate/delete-recreate/no-op/uninstall/restore); prints only hashes and states, never secret values; reconciles from the current pushed branch, restores to main
	@sh tests/eso/test-secret-lifecycle.sh

eso-test-provision-source-secret-idempotency: ## Phase 2.6.3b: mutating proof of provision-source-secret.sh's ensure/--rotate/--delete semantics and the global kubeconfig fingerprint helper's isolation (restores the pre-test value/state on exit)
	@sh tests/eso/test-provision-source-secret-idempotency.sh

# Phase 2.7.1: Terraform toolchain and offline validation only. No
# target below ever runs `plan`/`apply` against real AWS, contacts an
# AWS endpoint, or requires an AWS account/credential/profile - see
# .local/evidence/phase-2.7-eks-aws-foundation-plan.md and
# docs/adr/0011-terraform-foundation.md. `terraform` itself is
# installed exclusively via `make tools-install` (the same pinned,
# checksum-verified .tools/bin/ pipeline as kind/kubectl/helm) - never
# globally, never via a GitHub Action.
terraform-fmt: ## Phase 2.7.1: terraform fmt -check against terraform/ (fully offline, zero AWS contact)
	@.tools/bin/terraform -chdir=terraform fmt -check -diff -recursive

terraform-init: ## Phase 2.7.1: terraform init -backend=false against terraform/ (only network contact is the public Terraform Registry fetching the pinned provider binary; zero AWS contact, no backend, no state)
	@.tools/bin/terraform -chdir=terraform init -backend=false

terraform-validate: ## Phase 2.7.1: terraform validate against terraform/ (syntax/internal-consistency only; run terraform-init first; never contacts AWS or any provider API)
	@.tools/bin/terraform -chdir=terraform validate

terraform-test: ## Phase 2.7.1: terraform test against terraform/tests/ using mock_provider "aws" (zero AWS credentials, zero AWS network contact, zero real resources created; run terraform-init first)
	@.tools/bin/terraform -chdir=terraform test

terraform-validate-offline: ## Phase 2.7.1: full offline Terraform toolchain validation in one pass (fmt -check, init -backend=false, validate, test/mock_provider); never plan/apply against AWS, zero AWS contact
	@.tools/bin/terraform -chdir=terraform fmt -check -diff -recursive
	@.tools/bin/terraform -chdir=terraform init -backend=false
	@.tools/bin/terraform -chdir=terraform validate
	@.tools/bin/terraform -chdir=terraform test
	@echo "OK: terraform-validate-offline passed - fmt/init(-backend=false)/validate/test all offline, zero AWS contact"
