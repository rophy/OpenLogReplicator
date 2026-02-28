#!/bin/sh
set -eu

export BUILD_TAG="${BUILD_TAG:-$(git describe --tags --always)}"
export GIDOLR="${GIDOLR:-$(id -g)}"
export UIDOLR="${UIDOLR:-$(id -u)}"
IMAGE="rophy/openlogreplicator:${BUILD_TAG}"

echo "Building ${IMAGE}"
docker compose build build

echo "Running tests"
docker run --rm --user root --entrypoint bash \
    "${IMAGE}" \
    -c "cd /opt/OpenLogReplicator-local/cmake-build-Debug-x86_64 && ctest --output-on-failure"
