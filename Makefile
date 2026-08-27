SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

APP       ?= mobileorders
PLATFORM  ?= android
SRC       ?= $(APP)/$(PLATFORM)

# Gitignored.
BUILD_DIR ?= build
ARTIFACT  ?= $(BUILD_DIR)/$(APP)-$(PLATFORM).zip

.PHONY: help package clean backend-build backend-test bootstrap-kosli infra-deploy infra-deploy-staging infra-oidc

help: ## Show this help
	@grep -hE '^[a-z][a-z-]*:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-21s\033[0m %s\n", $$1, $$2}'

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

package: $(ARTIFACT) ## Package the app source into build/
$(ARTIFACT): | $(BUILD_DIR)
	@# Placeholder artifact: something to fingerprint until there is a real build.
	zip -qr $(ARTIFACT) $(SRC)

clean: ## Remove everything generated
	rm -rf $(BUILD_DIR)

backend-build: ## Build the orders-api backend jar (mvn package)
	mvn -B --no-transfer-progress package

backend-test: ## Run the orders-api backend tests (mvn verify)
	mvn -B --no-transfer-progress verify

bootstrap-kosli: ## Create/update org-level Kosli types, controls and policies (needs KOSLI_ORG, KOSLI_API_TOKEN)
	./scripts/bootstrap_kosli.sh

infra-deploy: ## Create/update the production Azure infra (needs az login)
	./infra/deploy.sh prod

infra-deploy-staging: ## Create/update the staging Azure infra (needs az login)
	./infra/deploy.sh staging

infra-oidc: ## Set up GitHub OIDC federated credentials for Azure deploy (needs az + gh login)
	./infra/setup-github-oidc.sh
