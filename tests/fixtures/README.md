# Test Fixture Generation

Automated pipeline to generate regression test fixtures by comparing OLR output
against Oracle LogMiner ground truth.

## Prerequisites

- Running Oracle database (RAC VM or single-instance) with SSH access
- OLR binary built (`build-prod.sh` or `build-dev.sh`)
- Python 3.6+ on the host (stdlib only, no pip dependencies)
- Test user created in the PDB:

```sql
-- Connect as sysdba to PDB
ALTER SESSION SET CONTAINER = ORCLPDB;
CREATE USER olr_test IDENTIFIED BY olr_test
    DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
GRANT CONNECT, RESOURCE TO olr_test;
GRANT CREATE TABLE TO olr_test;
GRANT ALTER SYSTEM TO olr_test;  -- needed for log switches
GRANT SELECT ON v_$database TO olr_test;
```

## Quick Start

```bash
cd tests/fixtures

# Generate the basic-crud fixture (requires Oracle VM running):
./generate.sh basic-crud

# Run regression tests:
cd ../..
ctest --output-on-failure
```

## How It Works

The `generate.sh` script runs 7 stages:

| Stage | Action |
|-------|--------|
| 1 | Uploads and runs SQL scenario on Oracle VM, captures SCN range |
| 2 | Finds and downloads archived redo logs covering the SCN range |
| 3 | Creates schema directory (uses flags=2 schemaless mode) |
| 4 | Runs LogMiner on VM, downloads results, converts to JSON |
| 5 | Runs OLR locally in batch mode against the captured redo logs |
| 6 | Compares OLR output vs LogMiner output |
| 7 | If match, saves OLR output as golden file for regression tests |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_HOST` | `192.168.122.248` | Oracle VM IP address |
| `VM_KEY` | `oracle-rac/vm-key` | SSH private key path |
| `VM_USER` | `root` | SSH user |
| `OLR_BIN` | auto-detect | Path to OLR binary |
| `DB_CONN` | `olr_test/olr_test@//localhost:1521/ORCLPDB` | sqlplus connect string (test user) |
| `SYS_CONN` | `sys/oracle@//localhost:1521/ORCLPDB as sysdba` | sqlplus connect string (sysdba) |
| `SCHEMA_OWNER` | `OLR_TEST` | Schema owner for LogMiner filter |

## Directory Structure

```
tests/fixtures/
  generate.sh                   # Main orchestration script
  compare.py                    # OLR vs LogMiner comparison tool
  logminer2json.py              # LogMiner SQL_REDO → canonical JSON
  scenarios/                    # SQL workload scripts
    basic-crud.sql              # Simple INSERT/UPDATE/DELETE
  lib/                          # Shared SQL helpers
    logminer-extract.sql        # LogMiner query (parameterized by SCN range)
  README.md                     # This file

tests/data/                     # Generated fixture data (not in git)
  redo/<scenario>/              # Archived redo log files
  schema/<scenario>/            # Schema/checkpoint state
  expected/<scenario>/          # Golden output files
    output.json                 # OLR output (used by gtest)
    logminer-reference.json     # LogMiner output (for debugging)
```

## Writing New Scenarios

Create a SQL file in `scenarios/` that:

1. Creates test table(s) with supplemental logging
2. Records start SCN via `SELECT current_scn FROM v$database`
3. Performs DML operations with explicit COMMITs
4. Forces log switches (`ALTER SYSTEM SWITCH LOGFILE`)
5. Records end SCN
6. Outputs `FIXTURE_SCN_RANGE: <start> - <end>`

See `scenarios/basic-crud.sql` for the template.

## Comparison Details

The comparison (`compare.py`) works by:

- Parsing OLR JSON output (one object per line with `payload` array)
- Parsing LogMiner output normalized to JSON by `logminer2json.py`
- Matching operations in order (not by SCN — OLR uses LWN group SCNs)
- Type-aware value comparison (`"100"` matches `100`)
- Skipping begin/commit/checkpoint messages in OLR output

## Troubleshooting

If comparison fails, inspect the working directory (not cleaned up on failure):

```bash
# LogMiner parsed output
cat /tmp/olr_fixture_basic-crud_XXXXXX/logminer.json

# OLR raw output
cat /tmp/olr_fixture_basic-crud_XXXXXX/olr_output.json

# OLR log
cat /tmp/olr_fixture_basic-crud_XXXXXX/olr_stdout.log
```
