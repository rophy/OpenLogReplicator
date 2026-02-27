# Test Fixtures

This directory holds test fixture data for full pipeline I/O tests.
Fixtures are not checked into git (redo logs are large binary files).

## Directory Structure

```
data/
  redo/<fixture-name>/       # Archived redo log files (input)
  schema/<fixture-name>/     # Checkpoint/schema files (OLR state)
  expected/<fixture-name>/   # Expected JSON output (golden files)
```

## Capturing Fixtures

### Prerequisites
- Running Oracle database (single instance or RAC)
- OLR binary built and working against the database

### Steps

1. **Create a test table and run DML:**

```sql
-- Connect to PDB as test user
CREATE TABLE TEST_CDC (
    id NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    val NUMBER
);

-- For "single-transaction" fixture:
INSERT INTO TEST_CDC VALUES (1, 'Alice', 100);
COMMIT;

-- For "multiple-operations" fixture:
INSERT INTO TEST_CDC VALUES (2, 'Bob', 200);
UPDATE TEST_CDC SET val = 150 WHERE id = 1;
DELETE FROM TEST_CDC WHERE id = 2;
COMMIT;

-- Force archive log switch
ALTER SYSTEM SWITCH LOGFILE;
-- Wait a moment, then switch again to ensure archival
ALTER SYSTEM SWITCH LOGFILE;
```

2. **Identify the archived redo logs:**

```sql
SELECT NAME, SEQUENCE#, THREAD#, FIRST_CHANGE#
FROM V$ARCHIVED_LOG
WHERE FIRST_TIME > SYSDATE - 1/24
ORDER BY SEQUENCE#;
```

3. **Copy archived redo logs to fixture directory:**

```bash
mkdir -p tests/data/redo/single-transaction
cp /path/to/archive_logs/*.arc tests/data/redo/single-transaction/
```

4. **Generate expected output (run OLR once):**

Create a batch config pointing to the fixture redo logs with a file writer,
then run OLR:

```bash
mkdir -p tests/data/expected/single-transaction
./OpenLogReplicator -r -f test-config.json
cp output.json tests/data/expected/single-transaction/output.json
```

5. **Save schema/checkpoint if needed:**

```bash
mkdir -p tests/data/schema/single-transaction
cp checkpoint/* tests/data/schema/single-transaction/
```

### RAC Multi-Thread Fixture

For the `rac-multi-thread` fixture, run concurrent DML from both RAC nodes
to generate redo logs on multiple threads. Include archive logs from all
threads in `tests/data/redo/rac-multi-thread/`.

## Notes

- Use `"flags": 2` (schemaless mode) in test configs to avoid schema dependency
- Redo log files are Oracle-version-specific; fixtures captured on one version
  may not work on another
- Keep fixtures small (minimal DML) for fast test execution
