OLR_IMAGE ?= olr-dev:latest
CACHE_IMAGE ?= ghcr.io/bersler/openlogreplicator:ci
BUILD_TYPE ?= Debug
OLR_BUILD_DIR ?= /opt/OpenLogReplicator-local/cmake-build-$(BUILD_TYPE)-x86_64

.PHONY: build test-redo clean

build:
	docker buildx build \
		--build-arg BUILD_TYPE=$(BUILD_TYPE) \
		--build-arg UIDOLR=$$(id -u) \
		--build-arg GIDOLR=$$(id -g) \
		--build-arg GIDORA=54322 \
		--build-arg WITHORACLE=1 \
		--build-arg WITHKAFKA=1 \
		--build-arg WITHPROTOBUF=1 \
		--build-arg WITHPROMETHEUS=1 \
		--build-arg WITHTESTS=1 \
		--cache-from type=registry,ref=$(CACHE_IMAGE) \
		-t $(OLR_IMAGE) \
		--load \
		-f Dockerfile.dev .

test-redo:
	docker run --rm \
		-v $(CURDIR)/tests:/opt/OpenLogReplicator-local/tests \
		--entrypoint bash $(OLR_IMAGE) \
		-c "ctest --test-dir $(OLR_BUILD_DIR) --output-on-failure"

clean:
	rm -rf tests/3-generated tests/.work
