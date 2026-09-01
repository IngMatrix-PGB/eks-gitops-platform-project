.DEFAULT_GOAL := help

.PHONY: help validate check-markdown check-links check-adr check-secrets check-forbidden-terms check-tad check-private-untracked

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
