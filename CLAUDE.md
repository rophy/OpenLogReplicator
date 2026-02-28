# OpenLogReplicator

## Build

Prerequisites: Docker with BuildKit, docker compose.

```bash
# Dev build (auto-tags from git describe)
./scripts/build-image.sh

# Or manually with custom tag
BUILD_TAG=my-test GIDOLR=$(id -g) UIDOLR=$(id -u) docker compose build build
```

`Dockerfile.local` splits dependencies into cached layers + uses ccache via
BuildKit cache mounts. Only the OLR compilation layer rebuilds on source changes
(~1-2 min with ccache warm, vs ~15 min cold).

Image is tagged as `rophy/openlogreplicator:${BUILD_TAG:-latest}`.

For upstream release builds using `OpenLogReplicator-docker/Dockerfile`:
```bash
GIDOLR=$(id -g) UIDOLR=$(id -u) docker compose run --rm build ./build-prod.sh
```

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
