.DEFAULT_GOAL := help

.PHONY: help validate check-markdown check-links check-adr check-secrets check-forbidden-terms check-tad check-private-untracked \
	tools-check tools-install lab-create lab-status lab-destroy lab-test lab-test-lifecycle

help: ## Show this help
	@echo "eks-gitops-platform-project - available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

validate: check-markdown check-links check-adr check-secrets check-forbidden-terms check-tad check-private-untracked ## Run every Phase 1 documentation validation check

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

check-tad: ## Verify the Technical Architecture Document has all required sections
	@bash scripts/validate/check-tad-sections.sh

check-private-untracked: ## Verify local-only reference material is excluded and untracked
	@bash scripts/validate/check-private-untracked.sh

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
