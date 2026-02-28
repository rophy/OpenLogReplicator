#!/bin/sh
set -eu

export BUILD_TAG="${BUILD_TAG:-$(git describe --tags --always)}"
export GIDOLR="${GIDOLR:-$(id -g)}"
export UIDOLR="${UIDOLR:-$(id -u)}"

echo "Building rophy/openlogreplicator:${BUILD_TAG}"
docker compose build build
