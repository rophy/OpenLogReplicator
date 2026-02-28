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
  generate.sh                   # Main orchestration script
  compare.py                    # OLR vs LogMiner comparison tool
  logminer2json.py              # LogMiner SQL_REDO → canonical JSON
  scenarios/                    # SQL workload scripts
    basic-crud.sql              # Simple INSERT/UPDATE/DELETE
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
