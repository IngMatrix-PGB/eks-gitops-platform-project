.DEFAULT_GOAL := help

.PHONY: help validate check-markdown check-links check-adr check-secrets check-forbidden-terms check-forbidden-terms-regression check-tad check-private-untracked \
	check-standard-workload-chart check-spoke-access check-supply-chain check-tool-platforms-regression \
	tools-check tools-install lab-create lab-status lab-destroy lab-test lab-test-lifecycle lab-test-eks-identity-offline eks-test-spoke-secret image-build image-scan image-sbom image-all \
	argocd-chart-fetch argocd-render argocd-install argocd-status argocd-uninstall argocd-port-forward \
	argocd-test-runtime-health argocd-test-lifecycle \
	gitops-repo-setup gitops-repo-check gitops-repo-remove gitops-render gitops-bootstrap \
	gitops-status gitops-test gitops-uninstall gitops-test-lifecycle \
	gitops-switch-revision gitops-retire-appproject-kind gitops-resume-appproject-kind \
	gitops-test-revision-switch gitops-test-appproject-kind-retirement \
	eso-chart-fetch eso-render check-eso-chart eso-install eso-status eso-uninstall \
	eso-test-runtime-health eso-test-lifecycle \
	eso-provision-source-secret eso-test-secret-lifecycle eso-test-provision-source-secret-idempotency \
	terraform-fmt terraform-init terraform-validate terraform-test terraform-validate-offline \
	check-terraform-offline check-terraform-offline-regression \
	lab-mc-create lab-mc-destroy lab-mc-status mc-spoke-register mc-spoke-deregister \
	lab-mc-test-lifecycle mc-test-registration \
	mc-spoke-eso-install mc-spoke-source-secret mc-bootstrap mc-up mc-test-e2e \
	workload-test-resilience \
	metrics-server-chart-fetch metrics-server-render check-metrics-server-chart metrics-server-install \
	metrics-server-status metrics-server-uninstall mc-spoke-metrics-server workload-test-autoscaling \
	workload-hpa-handover

help: ## Show this help
	@echo "eks-gitops-platform-project - available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

validate: check-markdown check-links check-adr check-secrets check-forbidden-terms check-forbidden-terms-regression check-tad check-private-untracked check-standard-workload-chart check-spoke-access check-supply-chain check-tool-platforms-regression check-terraform-offline check-terraform-offline-regression lab-test-eks-identity-offline eks-test-spoke-secret ## Run every Phase 1 documentation validation check plus the standard-workload chart contract

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

check-spoke-access: ## Phase 3.4.4a: the shared spoke Role (platform/spoke-access/role.yaml) grants exactly the AppProject's namespaced kinds - no ClusterRole, no secrets, no wildcard
	@bash scripts/validate/check-spoke-access.sh

check-supply-chain: ## Phase 5.1a: SHA-pinned GitHub-owned actions only, no write permissions, digest-pinned non-root Dockerfiles, scan threshold, dated .trivyignore, Dependabot coverage
	@bash scripts/validate/check-supply-chain.sh

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

# Phase 2.7.3 (ADR-0015): lab-multicluster profile - the `management` hub
# plus one kind cluster per spoke. Every lab target above also accepts
# LAB_CLUSTER=lab-lite|hub|dev|uat|prod (default lab-lite), e.g.
# `make argocd-install LAB_CLUSTER=hub`.
lab-mc-create: ## Phase 2.7.3: create the hub + spokes (SPOKES=dev,uat default; prod opt-in); refuses while lab-lite exists or Docker memory is short
	@sh lab/multicluster/create.sh

lab-mc-destroy: ## Phase 2.7.3: destroy every lab-multicluster member (spokes first, hub last); never touches lab-lite
	@sh lab/multicluster/destroy.sh

lab-mc-status: ## Phase 2.7.3: read-only identity, registration (never the token), and memory report for every member
	@sh lab/multicluster/status.sh

mc-spoke-register: ## Phase 2.7.3: register SPOKE=<dev|uat|prod> with the hub's Argo CD (namespace-scoped RBAC, 24h token; re-run rotates it)
	@sh lab/multicluster/spoke-register.sh $(SPOKE)

mc-spoke-deregister: ## Phase 2.7.3: remove SPOKE=<dev|uat|prod> from the hub and delete its access objects (keeps the workload namespace)
	@sh lab/multicluster/spoke-deregister.sh $(SPOKE)

lab-mc-test-lifecycle: ## Phase 2.7.3: mutating create/no-op/destroy/no-op proof for the multicluster profile (no member may exist first)
	@sh tests/multicluster/test-lifecycle.sh

mc-test-registration: ## Phase 2.7.3: mutating registration/rotation/RBAC/cross-token/probe/deregistration proof (requires REVISION=<pushed branch>)
	@sh tests/multicluster/test-registration.sh

mc-spoke-eso-install: ## Phase 2.7.4: install ESO on SPOKE=<dev|uat|prod> - one scoped release that owns that spoke's own webhook/cert-controller
	@case "$(SPOKE)" in dev|uat|prod) ;; *) echo "FAIL: SPOKE must be exactly one of: dev uat prod (got '$(SPOKE)')" >&2; exit 1 ;; esac
	@LAB_CLUSTER=$(SPOKE) sh lab/eso/install.sh

mc-spoke-source-secret: ## Phase 2.7.4: ensure (or ACTION=--rotate/--delete) the ESO source Secret on SPOKE=<dev|uat|prod>; value from stdin or a hidden prompt, never an argument
	@case "$(SPOKE)" in dev|uat|prod) ;; *) echo "FAIL: SPOKE must be exactly one of: dev uat prod (got '$(SPOKE)')" >&2; exit 1 ;; esac
	@LAB_CLUSTER=$(SPOKE) sh lab/eso/provision-source-secret.sh $(SPOKE) $(ACTION)

mc-bootstrap: ## Phase 2.7.4: hub root Application, profile local-multicluster (one Application per registered spoke; accepts REVISION=)
	@LAB_CLUSTER=hub sh lab/gitops/bootstrap.sh

mc-up: ## Phase 2.7.4: idempotent end-to-end bring-up - clusters, hub Argo CD + repo, per-spoke register/ESO/source Secret, hub bootstrap (SPOKES=, REVISION=)
	@sh lab/multicluster/up.sh

mc-test-e2e: ## Phase 2.7.4: mutating end-to-end proof - generator selection, per-spoke ESO/rotation/self-heal isolation, safe deregistration, hub uninstall (requires REVISION=<pushed branch>)
	@sh tests/multicluster/test-e2e.sh

metrics-server-chart-fetch: ## Phase 2.8.2: download and checksum-verify the pinned metrics-server chart into .tools/charts/
	@sh lab/metrics-server/chart-fetch.sh

metrics-server-render: ## Phase 2.8.2: fully offline render of metrics-server with the lab values; proves object set, digest-pinned image, no RBAC wildcard, restricted security context
	@sh lab/metrics-server/render.sh

check-metrics-server-chart: metrics-server-render ## Phase 2.8.2: alias of metrics-server-render (needs the chart fetched; not part of validate, like check-eso-chart)

metrics-server-install: ## Phase 2.8.2: fail-closed idempotent install on lab-lite or LAB_CLUSTER=dev|uat|prod (never the hub); LAB-ONLY --kubelet-insecure-tls
	@sh lab/metrics-server/install.sh

metrics-server-status: ## Phase 2.8.2: read-only release/Deployment/APIService/node-metrics check (LAB_CLUSTER=)
	@sh lab/metrics-server/status.sh

metrics-server-uninstall: ## Phase 2.8.2: idempotent removal of the metrics-server release (LAB_CLUSTER=)
	@sh lab/metrics-server/uninstall.sh

mc-spoke-metrics-server: ## Phase 2.8.2: install metrics-server on SPOKE=<dev|uat|prod>
	@case "$(SPOKE)" in dev|uat|prod) ;; *) echo "FAIL: SPOKE must be exactly one of: dev uat prod (got '$(SPOKE)')" >&2; exit 1 ;; esac
	@LAB_CLUSTER=$(SPOKE) sh lab/metrics-server/install.sh

workload-hpa-handover: ## Phase 2.8.2: before Git enables an HPA for an existing Deployment, give its current spec.replicas a second field owner so Argo CD letting go never drops it to 1 (NS= DEPLOYMENT=, LAB_CLUSTER=)
	@sh lab/workload/hpa-handover.sh $(NS) $(DEPLOYMENT)

workload-test-autoscaling: ## Phase 2.8.2: mutating proof of the prod HPA - metrics served, static->HPA hand-over never below minReplicas, scale-up under load with Argo CD Synced, scale-down, static Deployments still reconciled (lab-lite or LAB_CLUSTER=prod)
	@sh tests/workload/test-autoscaling.sh

workload-test-resilience: ## Phase 2.8.1: mutating proof of the chart's resilience contract on the prod workload (zero-error rollout, PDB eviction, NetworkPolicy, spread, self-heal); lab-lite by default or LAB_CLUSTER=prod; RESILIENCE_BASELINE=1 adds an informational run without preStop
	@sh tests/workload/test-resilience.sh

lab-test-eks-identity-offline: ## Phase 3.3.4b: fully offline positive/negative matrix for check_eks_cluster_identity() (fake kubectl/aws, no cluster, no AWS, no network - DESIGNED/NOT DEPLOYED)
	@sh tests/lab/test-eks-identity-offline.sh

eks-test-spoke-secret: ## Phase 3.4.4b: offline matrix for lab/eks/spoke-cluster-secret.sh (EKS cluster Secret with awsAuthConfig, no token) + its selection contract with the aws-eks profile
	@sh tests/eks/test-spoke-cluster-secret.sh

image-build: ## Phase 5.1a: docker build of apps/smoke (unit tests in the build stage) + non-root check, saved as .tools/out/image/smoke.tar
	@sh scripts/image/image.sh build

image-scan: ## Phase 5.1a: trivy - fails on any fixable HIGH/CRITICAL vulnerability or HIGH/CRITICAL Dockerfile misconfiguration
	@sh scripts/image/image.sh scan

image-sbom: ## Phase 5.1a: syft - CycloneDX SBOM at .tools/out/image/smoke.cdx.json
	@sh scripts/image/image.sh sbom

image-all: ## Phase 5.1a: image-build + image-scan + image-sbom
	@sh scripts/image/image.sh all

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

gitops-render: ## Fully offline Helm render of gitops/bootstrap; proves exactly 1 AppProject/1 ApplicationSet/3 generators/0 Secrets/no wildcards (accepts REVISION=<value>)
	@sh lab/gitops/render.sh

gitops-bootstrap: ## Fail-closed idempotent apply of the root Application only (accepts REVISION=<value>, default main)
	@sh lab/gitops/bootstrap.sh

gitops-status: ## Report root Application/AppProject/ApplicationSet/generated Applications/ConfigMaps status (read-only)
	@sh lab/gitops/status.sh

gitops-test: ## Read-only runtime health checks against an already-bootstrapped Phase 2.3 state
	@sh tests/gitops/test-runtime-health.sh

gitops-uninstall: ## Two-phase transactional uninstall (Phase 2.6.3a): read-only preflight classification of dev/uat/prod, zero mutation on any unclassifiable object; then deletes the root Application (foreground cascade) and only namespaces Phase A cleared; retains a namespace an active ESO scoped release still targets; preserves Argo CD/CRDs/repo Secret/deploy key
	@sh lab/gitops/uninstall.sh

gitops-switch-revision: ## Phase 2.6.3a: safely switch the root Application's targetRevision in place (patch, never delete+recreate); preserves UID/finalizers; requires 3 stable reads; rolls back automatically on failure (REVISION=<value>)
	@sh lab/gitops/switch-revision.sh

gitops-retire-appproject-kind: ## Phase 2.6.3a: drain SecretStore/ExternalSecret from one environment before narrowing the AppProject whitelist (ENV=dev|uat|prod ACTION=--drain)
	@sh lab/gitops/retire-appproject-kind.sh $(ENV) $(ACTION)

gitops-resume-appproject-kind: ## Phase 2.6.3a: resume automated sync after retire-appproject-kind's drain + the whitelist-narrowing Git change have both landed (ENV=dev|uat|prod)
	@sh lab/gitops/retire-appproject-kind.sh $(ENV) --resume

gitops-test-lifecycle: ## Mutating: proves bootstrap/no-op/self-heal/isolation/uninstall/no-op end-to-end (requires REVISION=<pushed branch>)
	@sh tests/gitops/test-lifecycle.sh

gitops-test-revision-switch: ## Phase 2.6.3a: mutating, proves switch-revision.sh converges/rolls-back correctly (requires REVISION=<pushed branch>; switches back to BASE_REVISION, default main)
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

eso-uninstall: ## Uninstall all three scoped releases (prod, dev, then uat; accepts ENV=dev|uat|prod for one at a time); never touches the 25 CRDs; refuses to uninstall uat while dev or prod still exists
	@sh lab/eso/uninstall.sh $(ENV)

eso-test-runtime-health: ## Read-only runtime health checks against an already-installed ESO bootstrap
	@sh tests/eso/test-runtime-health.sh

eso-test-lifecycle: ## Mutating: proves install/no-op/uninstall(CRDs retained)/no-op/restore end-to-end
	@sh tests/eso/test-idempotency.sh

eso-provision-source-secret: ## Phase 2.6.2: create/rotate (default) or delete (ACTION=--delete) the imperative, out-of-Git source Secret for ENV=dev|uat|prod; value is read from stdin or an echo-disabled prompt, never a CLI argument
	@sh lab/eso/provision-source-secret.sh $(ENV) $(ACTION)

eso-test-secret-lifecycle: ## Phase 2.6.2: mutating end-to-end proof of the SecretStore/ExternalSecret contract (provision/reconcile/mount/rotate/propagate/delete-recreate/no-op/uninstall/restore); prints only hashes and states, never secret values; reconciles from the current pushed branch, restores to RESTORE_REVISION (default main)
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
terraform-fmt: ## Phase 3.1: terraform fmt -check against every terraform/*.tf file, recursively (fully offline, zero AWS contact) - a single recursive check from terraform/ already covers every root module and child module, since formatting is independent of root-module/state boundaries
	@.tools/bin/terraform -chdir=terraform fmt -check -diff -recursive

terraform-init: ## Phase 3.1: terraform init -backend=false in EVERY discovered Terraform root module (terraform/, terraform/bootstrap/, each terraform/envs/*/ - see scripts/lab/terraform-root-modules.sh, the single source of truth for this list); only network contact is the public Terraform Registry fetching pinned providers/modules; zero AWS contact, no backend, no state
	@for m in $$(sh scripts/lab/terraform-root-modules.sh); do \
		echo "terraform-init: $$m"; \
		.tools/bin/terraform -chdir="$$m" init -backend=false || exit 1; \
	done

terraform-validate: ## Phase 3.1: terraform validate in EVERY discovered Terraform root module (syntax/internal-consistency only; run terraform-init first; never contacts AWS or any provider API)
	@for m in $$(sh scripts/lab/terraform-root-modules.sh); do \
		echo "terraform-validate: $$m"; \
		.tools/bin/terraform -chdir="$$m" validate || exit 1; \
	done

terraform-test: ## Phase 3.1: terraform test in EVERY discovered Terraform root module using mock_provider "aws" where applicable (zero AWS credentials, zero AWS network contact, zero real resources created; run terraform-init first)
	@for m in $$(sh scripts/lab/terraform-root-modules.sh); do \
		echo "terraform-test: $$m"; \
		.tools/bin/terraform -chdir="$$m" test || exit 1; \
	done

terraform-validate-offline: ## Phase 3.1: full offline Terraform toolchain validation in one pass, across every discovered root module (fmt -check, init -backend=false, validate, test/mock_provider); never plan/apply against AWS, zero AWS contact
	@.tools/bin/terraform -chdir=terraform fmt -check -diff -recursive
	@for m in $$(sh scripts/lab/terraform-root-modules.sh); do \
		echo "terraform-validate-offline: $$m"; \
		.tools/bin/terraform -chdir="$$m" init -backend=false || exit 1; \
		.tools/bin/terraform -chdir="$$m" validate || exit 1; \
		.tools/bin/terraform -chdir="$$m" test || exit 1; \
	done
	@echo "OK: terraform-validate-offline passed for every discovered root module - fmt/init(-backend=false)/validate/test all offline, zero AWS contact"

check-terraform-offline: ## Phase 3.1: deterministic enforcement of the Terraform offline contract across every root module (exact pins per root, lockfile per root names the expected provider, no configured backend anywhere, no real AWS resource outside bootstrap/envs/*, no real AWS data source outside the narrow allowlist, no operative provider "aws" block, every AWS-referencing Terraform test declares mock_provider, no real terraform plan/apply in scripts/Makefile/workflows, no id-token/aws-actions/AWS-credential surface, no real account id/ARN, offline targets use -backend=false, nothing tracked that should not be)
	@bash scripts/validate/check-terraform-offline.sh

check-terraform-offline-regression: ## Regression-test check-terraform-offline.sh's accept/reject matrix against throwaway fixture repositories
	@sh tests/terraform/test-offline-contract.sh
