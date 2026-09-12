# jellium-desktop — developer front-door.
#
# The build system is `just` (see justfile). This Makefile wraps the common
# recipes so `make <target>` works like aether's, and adds the release `tag`
# target that pushes a version tag to trigger the GitHub release workflow
# (.github/workflows/release.yml).

RELEASE_BRANCH ?= main

default: help

#==========================================================================================
##@ Testing
#==========================================================================================
.PHONY: test
test: ## build + run the workspace test suite (just test)
	@just test

#==========================================================================================
##@ Building
#==========================================================================================
.PHONY: build
build: ## build + stage a runnable tree in build/ (just build)
	@just build

.PHONY: clean
clean: ## remove build/ and dist/, cargo clean (just clean)
	@just clean

#==========================================================================================
##@ Running
#==========================================================================================
.PHONY: run
run: ## run with debug logging, logs to build/run.log (just run)
	@just run

#==========================================================================================
##@ Lint
#==========================================================================================
.PHONY: lint
lint: ## fmt-check + clippy with -D warnings (just lint)
	@just lint

.PHONY: fmt
fmt: ## format the workspace (just fmt)
	@just fmt

#==========================================================================================
##@ Release
#==========================================================================================
.PHONY: check-branch
check-branch:
	@current_branch=$$(git symbolic-ref --short HEAD) && \
	if [ "$$current_branch" != "$(RELEASE_BRANCH)" ]; then \
		echo "Error: You are on branch '$$current_branch'. Please switch to '$(RELEASE_BRANCH)'."; \
		exit 1; \
	fi

.PHONY: check-git-clean
check-git-clean: # fail if the working tree has staged/unstaged changes
	@git diff --quiet && git diff --cached --quiet || \
		( echo ">> working tree is dirty; commit or stash first"; exit 1 )

.PHONY: tag
tag: check-git-clean check-branch ## push a version tag to publish a release: make tag version="v1.2.3"
	@[ "$(version)" ] || ( echo ">> version is not set, usage: make tag version=\"v1.2.3\""; exit 1 )
	@echo "$(version)" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$$' || \
		( echo ">> version must look like v1.2.3 or v1.2.3-rc.1 (got '$(version)')"; exit 1 )
	@git tag -d $(version) 2>/dev/null || true
	@git tag -a $(version) -m "Release version: $(version)"
	@git push --delete origin $(version) 2>/dev/null || true
	@git push origin $(version)
	@echo "pushed $(version) - the release workflow will build and attach the binaries"

#==========================================================================================
#  Help
#==========================================================================================
.PHONY: help
help: # Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
