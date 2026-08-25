SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

APP       ?= mobileorders
PLATFORM  ?= android
SRC       ?= $(APP)/$(PLATFORM)

# Gitignored.
BUILD_DIR ?= build
ARTIFACT  ?= $(BUILD_DIR)/$(APP)-$(PLATFORM).zip

.PHONY: help package clean

help: ## Show this help
	@grep -hE '^[a-z][a-z-]*:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

package: $(ARTIFACT) ## Package the app source into build/
$(ARTIFACT): | $(BUILD_DIR)
	@# Placeholder artifact: something to fingerprint until there is a real build.
	zip -qr $(ARTIFACT) $(SRC)

clean: ## Remove everything generated
	rm -rf $(BUILD_DIR)
