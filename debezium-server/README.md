# Debezium Server: Oracle to File

This example runs Debezium Server to capture CDC changes from Oracle and write them to a file.

Since Debezium Server doesn't have a native file sink, we use an HTTP sink with a simple Python service that writes events to a file.

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐     ┌──────────────┐
│   Oracle    │────▶│ Debezium Server  │────▶│ File Writer │────▶│ events.json  │
│  (LogMiner) │     │  (HTTP Sink)     │     │  (Python)   │     │              │
└─────────────┘     └──────────────────┘     └─────────────┘     └──────────────┘
```

## Prerequisites

1. Docker and Docker Compose
2. Oracle database image: `oracle/database:21.3.0-xe`
   - Pre-built image available: `docker pull rophy/oracle-database:21.3.0-xe && docker tag rophy/oracle-database:21.3.0-xe oracle/database:21.3.0-xe`

## End-to-End Test Steps

### Step 1: Download Oracle JDBC Driver

Debezium requires the Oracle JDBC driver which is not bundled due to licensing.

```bash
./download-oracle-driver.sh
```

### Step 2: Initialize Directories

Create required directories with proper permissions (Oracle runs as UID 54321):

```bash
./init.sh
```

### Step 3: Fix File Permissions

Ensure config and setup files are readable:

```bash
chmod 644 config/application.properties
chmod 644 setup/01_setup.sql
```

### Step 4: Start Services

```bash
docker compose up -d
```

This starts three containers:
- `oracle-debezium`: Oracle 21c XE database
- `file-writer`: Python HTTP server that writes events to file
- `debezium-server`: Debezium Server with Oracle connector

### Step 5: Wait for Oracle to Initialize

First startup takes several minutes while Oracle creates the database:

```bash
timeout 600 bash -c 'until docker logs oracle-debezium 2>&1 | grep -q "DATABASE IS READY TO USE"; do sleep 10; echo "Waiting for Oracle..."; done'
echo "Oracle is ready!"
```

### Step 6: Run Oracle Setup Script

The setup script enables ARCHIVELOG mode, creates the Debezium user, and sets up the test schema:

```bash
docker exec oracle-debezium bash -c 'source /home/oracle/.bashrc && sqlplus / as sysdba @/opt/oracle/scripts/setup/01_setup.sql'
```

**Note:** Some errors about tablespace/user creation are expected on the first run due to path issues. We'll fix them in the next step.

### Step 7: Create PDB Objects Manually

Run this to create the tablespace, user, and test table in the PDB:

```bash
docker exec oracle-debezium bash -c 'source /home/oracle/.bashrc && sqlplus / as sysdba <<EOF
ALTER SESSION SET CONTAINER = XEPDB1;

-- Create tablespace
CREATE TABLESPACE TBLS1 DATAFILE '\''/opt/oracle/oradata/XE/XEPDB1/tbls1.dbf'\'' SIZE 100M AUTOEXTEND ON NEXT 100M;
ALTER TABLESPACE TBLS1 FORCE LOGGING;

-- Create test user
CREATE USER USR1 IDENTIFIED BY USR1PWD DEFAULT TABLESPACE TBLS1;
ALTER USER USR1 QUOTA UNLIMITED ON TBLS1;
GRANT CONNECT, RESOURCE TO USR1;

-- Create test table
CREATE TABLE USR1.ADAM1(
  ID         NUMBER NOT NULL,
  NAME       VARCHAR2(30),
  COUNT      NUMBER,
  START_TIME TIMESTAMP,
  CONSTRAINT ADAM1PK PRIMARY KEY(ID)
);
ALTER TABLE USR1.ADAM1 ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Insert initial data
INSERT INTO USR1.ADAM1 VALUES (1, '\''Initial Row'\'', 100, SYSTIMESTAMP);
COMMIT;

-- Grant Debezium user quota for LogMiner flush table
ALTER USER c##dbzuser QUOTA UNLIMITED ON USERS;

EXIT;
EOF'
```

### Step 8: Restart Debezium Server

Clear any stale state and restart:

```bash
rm -f data/offsets.dat data/schema-history.dat output/events.json
docker restart debezium-server
```

### Step 9: Verify Debezium is Streaming

Wait for snapshot to complete and streaming to start:

```bash
sleep 20
docker logs --tail 10 debezium-server 2>&1 | grep -E "(Snapshot completed|Starting streaming|Redo Log)"
```

You should see:
- `Snapshot completed`
- `Starting streaming`
- `Redo Log Group Sizes`

### Step 10: Run Test SQL

Execute INSERT, UPDATE, DELETE operations:

```bash
docker exec oracle-debezium bash -c 'source /home/oracle/.bashrc && sqlplus USR1/USR1PWD@//localhost:1521/XEPDB1 <<EOF
INSERT INTO ADAM1 VALUES (2, '\''CDC Test'\'', 200, SYSTIMESTAMP);
COMMIT;
UPDATE ADAM1 SET COUNT = 999 WHERE ID = 2;
COMMIT;
DELETE FROM ADAM1 WHERE ID = 2;
COMMIT;
EOF'
```

### Step 11: Verify Captured Events

Wait for events to be processed and check the output:

```bash
sleep 15
echo "Events captured: $(wc -l < output/events.json)"
cat output/events.json
```

Expected output: 5 events
1. Schema DDL (CREATE TABLE)
2. Snapshot read of initial row (ID=1)
3. INSERT (ID=2, "CDC Test")
4. UPDATE (COUNT changed to 999)
5. DELETE (ID=2)

## Event Format

Events are written as JSON lines. Example INSERT event:

```json
{
  "before": null,
  "after": {
    "ID": {"scale": 0, "value": "Ag=="},
    "NAME": "CDC Test",
    "COUNT": {"scale": 0, "value": "AMg="},
    "START_TIME": 1765860976102809
  },
  "source": {
    "connector": "oracle",
    "db": "XEPDB1",
    "schema": "USR1",
    "table": "ADAM1",
    "snapshot": "false"
  },
  "op": "c"
}
```

Operation types:
- `r` = read (snapshot)
- `c` = create (INSERT)
- `u` = update (UPDATE)
- `d` = delete (DELETE)

## Cleanup

```bash
docker compose down -v
sudo rm -rf oradata fra data output/*.json
```

## Troubleshooting

### Debezium fails with "ORA-01017: invalid username/password"

The setup script didn't run. Execute Step 6 manually.

### Debezium fails with "ORA-01950: no privileges on tablespace 'USERS'"

The Debezium user needs tablespace quota:

```bash
docker exec oracle-debezium bash -c 'source /home/oracle/.bashrc && sqlplus / as sysdba <<EOF
ALTER SESSION SET CONTAINER = XEPDB1;
ALTER USER c##dbzuser QUOTA UNLIMITED ON USERS;
EXIT;
EOF'
docker restart debezium-server
```

### No CDC events captured (only snapshot)

1. Check Debezium logs for errors: `docker logs debezium-server`
2. Ensure ARCHIVELOG mode is enabled
3. Verify supplemental logging is enabled on the table

### Permission denied on config files

```bash
chmod 644 config/application.properties
chmod 644 setup/01_setup.sql
docker restart debezium-server
```

## Comparison with OpenLogReplicator

| Aspect | OpenLogReplicator | Debezium Server |
|--------|-------------------|-----------------|
| Redo log access | Direct parsing | LogMiner |
| File sink | Native | Via HTTP + service |
| Setup complexity | Lower | Higher |
| Required privileges | Fewer | More (LogMiner) |
| Output format | JSON | JSON (configurable) |
