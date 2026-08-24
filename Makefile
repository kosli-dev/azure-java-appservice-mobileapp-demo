SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

MOBSFSCAN_IMAGE ?= opensecurity/mobsfscan:latest

APP       ?= mobilepay
PLATFORM  ?= android
SRC       ?= $(APP)/$(PLATFORM)

# Gitignored.
BUILD_DIR ?= build
SARIF     ?= $(BUILD_DIR)/mobsfscan-$(PLATFORM).sarif
ARTIFACT  ?= $(BUILD_DIR)/$(APP)-$(PLATFORM).zip

MOBSFSCAN := docker run --rm -v "$(PWD):/src" -w /src $(MOBSFSCAN_IMAGE)

.PHONY: help scan package clean

help: ## Show this help
	@grep -hE '^[a-z][a-z-]*:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

scan: | $(BUILD_DIR) ## Scan the app source into build/
	@# || true: findings must not fail the build. Kosli is the gate, not mobsfscan.
	$(MOBSFSCAN) --sarif --type $(PLATFORM) $(SRC) > $(SARIF) || true

package: $(ARTIFACT) ## Package the app source into build/
$(ARTIFACT): | $(BUILD_DIR)
	@# Placeholder artifact: something to fingerprint until there is a real build.
	zip -qr $(ARTIFACT) $(SRC)

clean: ## Remove everything generated
	rm -rf $(BUILD_DIR)
