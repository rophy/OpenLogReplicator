# OpenLogReplicator Test Framework

Automated regression testing for OpenLogReplicator. Each test runs OLR in batch
mode against captured Oracle redo logs and compares JSON output against golden
files validated by Oracle LogMiner.

## Prerequisites

- Docker with Compose v2
- Python 3.6+ (stdlib only, no pip dependencies)
- Bash

No C++ toolchain needed on the host — OLR is built inside Docker.

## Quick Start

```bash
# Build OLR Docker image (includes binary + gtest)
make build

# Start OLR dev container + Oracle (~30s with slim-faststart image)
make up

# Generate all fixtures (validates each against LogMiner)
make testdata

# Run regression tests
make test

# Generate just one fixture
make testdata SCENARIO=basic-crud

# Cleanup
make down
```

## How It Works

### Build (`make build`)

Builds OLR inside a Docker image (`olr-dev`) using `Dockerfile.dev` at the
project root via `docker compose build olr`. The image includes all optional
dependencies (Oracle client, Kafka, Protobuf, Prometheus) with ccache for
fast incremental rebuilds. Google Test is auto-fetched via CMake FetchContent.

### Fixture Generation (`make testdata`)

The `scripts/generate.sh` script runs 7 stages per scenario:

| Stage | Action |
|-------|--------|
| 0 | (DDL only) Build LogMiner dictionary into redo logs |
| 1 | Run SQL scenario against Oracle, capture start/end SCN |
| 2 | Force log switches, copy archived redo logs out of container |
| 3 | Generate schema checkpoint via `gencfg.sql` |
| 4 | Run LogMiner, convert output to JSON |
| 5 | Run OLR in batch mode via `docker run` against captured redo logs |
| 6 | Compare OLR output vs LogMiner — **fail if mismatch** |
| 7 | Save OLR output as golden file |

### Regression Tests (`make test`)

Runs `ctest` inside the `olr-dev` Docker image with fixture directories mounted.
The C++ test runner (`test_pipeline.cpp`) auto-discovers fixtures from
`3-expected/*/output.json`, builds a batch-mode config for each, runs OLR,
and compares output line-by-line against the golden file.

No Oracle instance is needed to run tests — only the pre-generated fixtures.

## Directory Structure

```
Makefile                            # Build, run, test targets
Dockerfile.dev                      # Builds OLR + gtest (full dev image)
docker-compose.yaml                 # olr (dev container) + oracle (test DB)
scripts/run.sh                      # Docker entrypoint script
tests/
  CMakeLists.txt                    # gtest build config
  test_pipeline.cpp                 # Parameterized gtest runner
  scripts/
    generate.sh                     # Generate + validate one fixture
    compare.py                      # OLR vs LogMiner comparison
    logminer2json.py                # LogMiner spool → JSON converter
    oracle-init/
      01-setup.sh                   # Enables archivelog + supplemental logging
  0-inputs/                         # SQL scenarios (committed)
    basic-crud.sql
    data-types.sql
    ...
  1-schema/                         # Schema checkpoints (gitignored)
  2-redo/                           # Redo log files (gitignored)
  3-expected/                       # Golden files (gitignored)
```

Only `0-inputs/`, `scripts/`, and build files are committed to git. The `1-schema/`, `2-redo/`, and `3-expected/` directories are generated
and distributed as CI artifacts.

## Writing New Scenarios

Create a SQL file in `0-inputs/` that:

1. Creates test table(s) with supplemental logging
2. Records start SCN via `DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || scn)`
3. Performs DML operations with explicit COMMITs
4. Records end SCN via `DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_END: ' || scn)`
5. Ends with `EXIT`

See `0-inputs/basic-crud.sql` for the template.

**Note:** Log switches are handled by `generate.sh` — don't run
`ALTER SYSTEM SWITCH LOGFILE` from the scenario SQL.

### DDL Scenarios

For scenarios with DDL (ALTER TABLE, etc.), add `-- @DDL` at the top.
This switches LogMiner to `DICT_FROM_REDO_LOGS` + `DDL_DICT_TRACKING`
so it can track schema changes inline.

See `0-inputs/ddl-add-column.sql` for an example.

### Long-Spanning Transactions

For transactions that should span multiple archive logs, add `-- @MID_SWITCH`
markers in the SQL where log switches should occur. The SQL should use
`DBMS_SESSION.SLEEP()` at those points to allow time for the switch.

See `0-inputs/long-spanning-txn.sql` for an example.

## Comparison Details

The comparison tool (`scripts/compare.py`) handles:

- **Content-based matching**: pairs records by operation type, table, and column
  values rather than strict ordering (LogMiner orders by redo SCN, OLR by
  commit SCN)
- **Type tolerance**: `"100"` matches `100`, float precision differences allowed
- **Date/timestamp conversion**: Oracle format strings vs epoch seconds
- **LOB merging**: Oracle splits LOB writes into INSERT(EMPTY_CLOB) + UPDATE;
  these are merged to match OLR's coalesced output
- **Supplemental log columns**: OLR includes all columns via supplemental
  logging; extra columns beyond what LogMiner shows are allowed

## CI Workflows

### `generate-fixtures.yaml`

Runs weekly (or manually via `workflow_dispatch`). Starts Oracle, generates all
fixtures with LogMiner validation, uploads as artifact (90-day retention).

### `run-tests.yaml`

Runs on push/PR to master. Downloads the latest fixture artifact and runs
`ctest` inside the `olr-dev` Docker image. **Fails hard** if no artifact exists —
run `generate-fixtures` first.

## Makefile Targets

| Target | Description |
|--------|-------------|
| `build` | Build OLR Docker image with tests |
| `up` | Start OLR dev container + Oracle container |
| `down` | Stop all containers |
| `test` | Run regression tests via `ctest` (inside Docker) |
| `testdata` | Generate all fixtures (or one with `SCENARIO=name`) |
| `clean` | Remove generated fixture data |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ORACLE_CONTAINER` | `oracle` | Docker container name for Oracle |
| `ORACLE_PASSWORD` | `oracle` | SYS/SYSTEM password |
| `DB_CONN` | `olr_test/olr_test@//localhost:1521/FREEPDB1` | Test user connect string |
| `SCHEMA_OWNER` | `OLR_TEST` | Schema owner for LogMiner filter |
| `PDB_NAME` | `FREEPDB1` | PDB name for schema generation |

## Troubleshooting

If fixture generation fails at comparison, the working directory is preserved:

```bash
# LogMiner parsed output
cat tests/.work/basic-crud_XXXXXX/logminer.json

# OLR raw output
cat tests/.work/basic-crud_XXXXXX/olr_output.json

# OLR log (includes redo parsing details)
cat tests/.work/basic-crud_XXXXXX/olr_stdout.log

# Generated OLR config
cat tests/.work/basic-crud_XXXXXX/olr_config.json
```
