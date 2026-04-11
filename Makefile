OLR_IMAGE ?= olr-dev:latest
CACHE_IMAGE ?= ghcr.io/bersler/openlogreplicator:ci
BUILD_TYPE ?= Debug
OLR_VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

FIXTURE_ARCHIVES := $(wildcard tests/fixtures/*.tar.gz)
FIXTURE_DIRS := $(FIXTURE_ARCHIVES:.tar.gz=)

.PHONY: help build build-release test-redo extract-fixtures fixtures clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build OLR dev image (Debug)
	docker buildx build \
		--build-arg BUILD_TYPE=$(BUILD_TYPE) \
		--build-arg OLR_VERSION=$(OLR_VERSION) \
		--build-arg UIDOLR=$$(id -u) \
		--build-arg GIDOLR=$$(id -g) \
		--build-arg GIDORA=54322 \
		--build-arg WITHORACLE=1 \
		--build-arg WITHKAFKA=1 \
		--build-arg WITHPROTOBUF=1 \
		--build-arg WITHPROMETHEUS=1 \
		--cache-from type=registry,ref=$(CACHE_IMAGE) \
		-t $(OLR_IMAGE) \
		--load \
		-f Dockerfile.dev .

build-release: ## Build OLR release image (minimal, multi-stage)
	docker buildx build \
		--build-arg OLR_VERSION=$(OLR_VERSION) \
		--build-arg GIDOLR=$$(id -u) \
		--build-arg UIDOLR=$$(id -u) \
		--build-arg WITHORACLE=1 \
		--build-arg WITHKAFKA=1 \
		--build-arg WITHPROTOBUF=1 \
		--build-arg WITHPROMETHEUS=1 \
		-t rophy/openlogreplicator:$(OLR_VERSION) \
		--load \
		-f Dockerfile.release .

tests/fixtures/%: tests/fixtures/%.tar.gz
	rm -rf $@
	tar xzf $< -C tests/fixtures/
	touch $@

extract-fixtures: $(FIXTURE_DIRS) ## Extract fixture archives

test-redo: extract-fixtures ## Run redo log regression tests (no Oracle needed)
	cd tests && OLR_IMAGE=$(OLR_IMAGE) pytest fixtures/test_fixtures.py -v --tb=short $(PYTEST_ARGS)

fixtures: ## Archive generated fixtures as tar.gz for committing
	@for dir in tests/sql/generated/*/; do \
		[ -d "$$dir" ] || continue; \
		name=$$(basename "$$dir"); \
		echo "Archiving $$name..."; \
		tar czf "tests/fixtures/$$name.tar.gz" -C tests/sql/generated "$$name/"; \
	done

clean: ## Remove generated fixtures and working directories
	rm -rf tests/sql/generated tests/.work $(FIXTURE_DIRS)
