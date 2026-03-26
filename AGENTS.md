# OpenLogReplicator

## Build

Prerequisites: Docker with BuildKit, docker compose.

```bash
# Dev build
make build

# Or manually
DOCKER_BUILDKIT=1 docker build -f Dockerfile.dev \
  --build-arg GIDOLR=$(id -g) --build-arg UIDOLR=$(id -u) \
  -t olr-dev:latest .
```

`Dockerfile.dev` splits dependencies into cached layers + uses ccache via
BuildKit cache mounts. Only the OLR compilation layer rebuilds on source changes
(~1-2 min with ccache warm, vs ~15 min cold).

## Tests

```bash
# Run redo log regression tests (no Oracle needed)
make test-redo

# Run SQL tests against live Oracle
cd tests && pytest test_e2e.py -v --oracle-env=free-23

# Archive generated fixtures for committing
make fixtures
```

**IMPORTANT:** SQL tests for different Oracle environments (free-23, xe-21, etc.)
must NOT run in parallel. They share the container name `oracle` to enforce this.
Run one environment at a time — bring it down before starting another.

Redo log tests run OLR in batch mode against captured redo log fixtures
(compressed as `tests/fixtures/*.tar.gz`, extracted on demand) and compare
JSON output against golden files.

To generate fixtures, use `tests/sql/scripts/generate.sh` which runs SQL
scenarios against Oracle, captures redo logs, validates OLR output against
LogMiner, and saves golden files.
See [`tests/README.md`](tests/README.md) for details.

## Pull Requests

**IMPORTANT:** After opening a PR, you MUST wait for CodeRabbit to review.
Do NOT merge without PR review approvals. Do NOT ask the user to merge
without approvals.

## Known Limitations

All known limitations of Oracle LogMiner, Debezium, and OLR that affect test
behavior are documented in [`tests/KNOWN-LIMITATIONS.md`](tests/KNOWN-LIMITATIONS.md).

**IMPORTANT:** Any claim that something is a "known limitation", "by design",
or "cannot be done" MUST reference a specific entry (L1-L9) in that document.
If no entry exists, investigate and add one with evidence before making the
claim. Do NOT add entries without evidence from source code, documentation, or
reproducible test results.
