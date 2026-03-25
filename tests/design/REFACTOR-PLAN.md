# Test Framework Refactor Plan

## Current Problems

1. **Scattered layout** — Debezium tests split across `tests/debezium/` and
   `tests/sql/environments/rac/debezium/` with duplicated configs and scripts
2. **Multiple docker-compose files** for the same services with slightly different
   configs (twin-test vs perf vs checkpoint-restart)
3. **OLR started manually via SSH** in every RAC test script — duplicated
   `podman run` commands with subtle differences (DNS, network, ports)
4. **No shared entry point** — each test type has its own startup/cleanup
   conventions, easy to miss steps (e.g., Prometheus not started)
5. **Environment configs mixed with test logic** — OLR configs, Debezium
   properties, and Oracle init scripts scattered across test directories
6. **Pytest files at wrong level** — `test_e2e.py` and `test_fixtures.py`
   at `tests/` root but logically belong to `sql/` and `fixtures/`

## Target Structure

```
tests/
  environments/                    # Shared Oracle environments
    free-23/
      docker-compose.yaml
      oracle-init/
      .env
    xe-21/
      docker-compose.yaml
      oracle-init/
      .env
    xe-21-official/
      ...
    enterprise-19/
      ...
    rac/
      vm-env.sh                    # Auto-detect VM IP, validate configs
      up.sh                        # Verify VM + Oracle reachable
      down.sh
      .env
      olr.sh                       # Shared OLR start/stop on VM (single source)

  sql/                             # SQL e2e fixture generation
    inputs/                        # *.sql and *.rac.sql scenarios
    scripts/
      generate.sh                  # 7-stage pipeline
      compare.py                   # Content-based comparison
      logminer2json.py
      drivers/
        base.sh
        docker.sh
        local.sh
        rac.sh
    generated/                     # gitignored output
    test_e2e.py                    # pytest entry: SQL e2e
    conftest.py                    # SQL-specific pytest config

  fixtures/                        # Redo log regression (batch replay)
    *.tar.gz                       # Pre-captured archives
    test_fixtures.py               # pytest entry: redo regression
    conftest.py                    # Fixtures-specific pytest config

  dbz-twin/                        # Debezium twin-test (LogMiner vs OLR)
    debezium-receiver.py           # HTTP receiver (shared by twin + perf)
    compare-debezium.py            # Event comparison
    docker-compose.yaml            # Single-instance: receiver + adapters
    config/
      olr-config.json              # Single-instance OLR config
      application-logminer.properties
      application-olr.properties
    run.sh                         # Run twin-test per scenario
    checkpoint-restart-test.sh     # Single-instance fault tolerance
    rac/                           # RAC extensions
      docker-compose.yaml          # RAC: receiver + adapters (host network)
      config/
        olr-config.json            # RAC OLR config (SCAN connection)
        application-logminer.properties
        application-olr.properties
      checkpoint-restart-test.sh   # RAC fault tolerance
      soak-test.sh                 # 2-hour soak wrapper
    perf/                          # Performance + durability (extends dbz-twin)
      docker-compose.yaml          # Adds: swingbench, validator, prometheus
      validator.py                 # Real-time event matching
      Dockerfile.swingbench
      run.sh                       # Manual perf orchestrator
      config/
        olr-config.json            # Perf OLR config (SOE schema)
        application-logminer.properties
        application-olr.properties
        prometheus.yml

  conftest.py                      # Root pytest config (shared markers, CLI args)
  pytest.ini                       # Pytest configuration
  README.md                        # Test framework documentation
```

## Key Changes

### 1. Move environments up
- `tests/sql/environments/*` → `tests/environments/*`
- All test types reference `tests/environments/<env>`

### 2. Consolidate Debezium tests
- `tests/debezium/` → `tests/dbz-twin/` (single-instance)
- `tests/sql/environments/rac/debezium/` → `tests/dbz-twin/rac/`
- `tests/sql/environments/rac/debezium/perf/` → `tests/dbz-twin/perf/`
- `debezium-receiver.py` moves to `tests/dbz-twin/` (shared by twin + perf)

### 3. Shared OLR helper for RAC
- New `tests/environments/rac/olr.sh` with functions:
  - `olr_start <config>` — podman run with DNS, network, volumes
  - `olr_stop` — podman rm
  - `olr_wait_ready` — poll logs for "processing redo log"
  - `olr_logs` — podman logs
- All RAC test scripts source this instead of duplicating podman commands

### 4. Move pytest files
- `tests/test_e2e.py` → `tests/sql/test_e2e.py`
- `tests/test_fixtures.py` → `tests/fixtures/test_fixtures.py`
- `tests/conftest.py` splits: shared part stays at root, specific parts
  move to `sql/conftest.py` and `fixtures/conftest.py`
- Update `pytest.ini` testpaths accordingly

### 5. Single docker-compose per context
- `dbz-twin/docker-compose.yaml` — single-instance twin-test
- `dbz-twin/rac/docker-compose.yaml` — RAC twin-test
- `dbz-twin/perf/docker-compose.yaml` — perf (extends RAC compose)
- Each compose is self-contained with all needed services

## Migration Steps

1. Create target directories
2. Move files with `git mv`
3. Update all path references in scripts (`source`, volume mounts, etc.)
4. Update `pytest.ini` testpaths
5. Create `environments/rac/olr.sh` shared helper
6. Update RAC test scripts to source `olr.sh`
7. Run full test suite to verify:
   - `make test-redo` (if fixtures available)
   - SQL e2e: free-23, xe-21, rac
   - Checkpoint-restart soak test
   - Perf validation test
8. Update `README.md`
9. Update `CLAUDE.md` / `AGENTS.md` if they reference old paths

## Risks

- **Many path references** — shell scripts use relative paths extensively.
  Need to update every `source`, `cd`, volume mount, and `$SCRIPT_DIR`
  reference.
- **CI workflows** — `.github/workflows/*.yaml` reference test paths.
  Must update simultaneously.
- **Large diff** — many files moved. Hard to review. Consider doing it in
  stages (environments first, then dbz-twin, then pytest).

## Staged Approach

**Phase 1**: Move environments
- `tests/sql/environments/` → `tests/environments/`
- Update all references

**Phase 2**: Consolidate dbz-twin
- Merge `tests/debezium/` + `tests/sql/environments/rac/debezium/` → `tests/dbz-twin/`
- Create shared OLR helper

**Phase 3**: Move pytest files
- Move `test_e2e.py`, `test_fixtures.py`, split `conftest.py`

**Phase 4**: Validate
- Run all test suites
- Update documentation
