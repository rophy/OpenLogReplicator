# OpenLogReplicator

## Build

Prerequisites: Docker, docker compose, and `OpenLogReplicator-docker` cloned as `./OpenLogReplicator-docker/`.

```bash
# Release build
GIDOLR=$(id -g) UIDOLR=$(id -u) docker compose run --rm build ./build-prod.sh

# Debug build
GIDOLR=$(id -g) UIDOLR=$(id -u) docker compose run --rm build ./build-dev.sh
```

The `docker-compose.yaml` mounts the source tree into the docker build context at
the path the Dockerfile expects (`OpenLogReplicator/`), and mounts the Docker socket
so `docker build` runs against the host daemon. No source copying needed.

## Tests

Tests use Google Test, fetched automatically via CMake FetchContent.

```bash
# Build with tests (inside docker build container or local cmake)
cmake ... -DWITH_TESTS=ON
make
ctest --output-on-failure
```

Pipeline tests run OLR in batch mode against captured redo log fixtures and
compare JSON output against golden files. Tests skip automatically if redo
log fixtures are not present (they are gitignored due to size).

To generate fixtures, use `tests/fixtures/generate.sh` which runs SQL
scenarios against Oracle, captures redo logs, validates OLR output against
LogMiner, and saves golden files. Requires the Oracle RAC VM running.
See [`tests/fixtures/README.md`](tests/fixtures/README.md) for details.
