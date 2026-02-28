# Test Fixture Generation

Automated pipeline to generate regression test fixtures by comparing OLR output
against Oracle LogMiner ground truth.

## Prerequisites

- Oracle RAC VM running with SSH access (see `oracle-rac/DEPLOY.md`)
- Docker on the host (OLR runs in a container)
- Python 3.6+ on the host (stdlib only, no pip dependencies)
- Test user created in the PDB:

```sql
-- Connect as sysdba to CDB, then switch to PDB
ALTER SESSION SET CONTAINER = ORCLPDB;
CREATE USER olr_test IDENTIFIED BY olr_test
    DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
GRANT CONNECT, RESOURCE TO olr_test;
GRANT CREATE TABLE TO olr_test;
GRANT SELECT ON v_$database TO olr_test;
```

## Quick Start

```bash
cd tests/fixtures

# Generate the basic-crud fixture (requires Oracle VM running):
./generate.sh basic-crud

# Run regression tests (from project root, inside build container):
ctest --output-on-failure
```

## How It Works

The `generate.sh` script runs 7 stages:

| Stage | Action |
|-------|--------|
| 1 | Uploads and runs SQL scenario in PDB via podman exec, captures start SCN |
| 2 | Forces log switches from CDB root, finds and downloads archived redo logs |
| 3 | Generates schema file via gencfg.sql (with RAC V$LOG fix) |
| 4 | Runs LogMiner on VM, downloads results, converts to JSON |
| 5 | Runs OLR in Docker container in batch mode against captured redo logs |
| 6 | Compares OLR output vs LogMiner output |
| 7 | If match, saves OLR output as golden file for regression tests |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_HOST` | `192.168.122.248` | Oracle VM IP address |
| `VM_KEY` | `oracle-rac/vm-key` | SSH private key path |
| `VM_USER` | `root` | SSH user |
| `OLR_IMAGE` | `rophy/openlogreplicator:1.8.7` | Docker image for OLR |
| `RAC_NODE` | `racnodep1` | Podman container name on VM |
| `ORACLE_SID` | `ORCLCDB1` | Oracle SID inside container |
| `DB_CONN` | `olr_test/olr_test@//racnodep1:1521/ORCLPDB` | sqlplus connect string (test user) |
| `SCHEMA_OWNER` | `OLR_TEST` | Schema owner for LogMiner filter |
| `DML_THREAD` | `1` | RAC thread number that generated the DML |

## Directory Structure

```
tests/fixtures/
  generate.sh                   # Single-thread fixture generator
  generate-rac.sh               # RAC multi-thread fixture generator
  compare.py                    # OLR vs LogMiner comparison tool
  logminer2json.py              # LogMiner SQL_REDO → canonical JSON
  scenarios/                    # SQL workload scripts
    basic-crud.sql              # Simple INSERT/UPDATE/DELETE
    rac-interleaved.rac.sql     # RAC: alternating DML from both nodes
    rac-concurrent-tables.rac.sql # RAC: each node on different tables
    rac-thread2-only.rac.sql    # RAC: all DML on node 2
  lib/                          # Shared SQL helpers
    logminer-extract.sql        # LogMiner query template
  README.md                     # This file

tests/data/                     # Generated fixture data
  redo/<scenario>/              # Archived redo log files (gitignored)
  schema/<scenario>/            # Schema checkpoint files
  expected/<scenario>/          # Golden output files
    output.json                 # OLR output (used by gtest)
```

## Writing New Scenarios

Create a SQL file in `scenarios/` that:

1. Creates test table(s) with supplemental logging
2. Records start SCN: `DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || scn)`
3. Performs DML operations with explicit COMMITs
4. Records end SCN: `DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_END: ' || scn)`

Note: log switches are handled by `generate.sh` from CDB root (can't run
`ALTER SYSTEM SWITCH LOGFILE` from a PDB).

See `scenarios/basic-crud.sql` for the template.

## Comparison Details

The comparison (`compare.py`) works by:

- Parsing OLR JSON output (one object per line with `payload` array)
- Parsing LogMiner output normalized to JSON by `logminer2json.py`
- Matching operations in order (not by SCN — OLR uses LWN group SCNs)
- Type-aware value comparison (`"100"` matches `100`)
- Skipping begin/commit/checkpoint messages in OLR output
- For UPDATEs: OLR includes all columns via supplemental logging, while
  LogMiner only shows changed columns in `after` — extra OLR columns are allowed

## RAC Multi-Thread Fixtures

For testing OLR's RAC support (multi-thread redo parsing), use `generate-rac.sh`
with `.rac.sql` scenario files.

### Quick Start

```bash
cd tests/fixtures
./generate-rac.sh rac-interleaved
```

### How It Differs from generate.sh

| Aspect | generate.sh | generate-rac.sh |
|--------|-------------|-----------------|
| SQL format | Single `.sql` file | Block-based `.rac.sql` with `@SETUP`/`@NODE1`/`@NODE2` markers |
| DML execution | Single node | Multiple nodes (each block runs on its designated node) |
| Log switch | `SWITCH LOGFILE` | `SWITCH ALL LOGFILE` (all RAC instances) |
| Archive capture | Single thread (`DML_THREAD` filter) | All threads (no filter) |

### .rac.sql Block Format

```sql
-- @SETUP
-- Runs on node 1 as sysdba context. Create tables, supplemental logging, capture start SCN.

-- @NODE1
-- DML block executed on node 1 (racnodep1, ORCLCDB1)

-- @NODE2
-- DML block executed on node 2 (racnodep2, ORCLCDB2)

-- @NODE1
-- Multiple blocks per node are supported, executed in order.
```

### Environment Variables (RAC-specific)

| Variable | Default | Description |
|----------|---------|-------------|
| `RAC_NODE1` | `racnodep1` | Podman container for node 1 |
| `RAC_NODE2` | `racnodep2` | Podman container for node 2 |
| `ORACLE_SID1` | `ORCLCDB1` | Oracle SID for node 1 |
| `ORACLE_SID2` | `ORCLCDB2` | Oracle SID for node 2 |
| `DB_CONN1` | `olr_test/olr_test@//racnodep1:1521/ORCLPDB` | PDB connect string via node 1 |
| `DB_CONN2` | `olr_test/olr_test@//racnodep2:1521/ORCLPDB` | PDB connect string via node 2 |

Common variables (`VM_HOST`, `VM_KEY`, `VM_USER`, `OLR_IMAGE`, `SCHEMA_OWNER`) are
shared with `generate.sh`.

### Available RAC Scenarios

| Scenario | Description |
|----------|-------------|
| `rac-interleaved` | Alternating DML on same table from both nodes |
| `rac-concurrent-tables` | Each node operates on different tables |
| `rac-thread2-only` | All DML on node 2 (thread 2) only |

## Troubleshooting

If comparison fails, the working directory is preserved (not cleaned up):

```bash
# LogMiner parsed output
cat /tmp/olr_fixture_basic-crud_XXXXXX/logminer.json

# OLR raw output
cat /tmp/olr_fixture_basic-crud_XXXXXX/olr_output.json

# OLR log
cat /tmp/olr_fixture_basic-crud_XXXXXX/olr_stdout.log
```
