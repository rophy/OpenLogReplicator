# Debezium Server: Oracle to File

This example runs Debezium Server to capture changes from Oracle and write them to a file.

Since Debezium Server doesn't have a native file sink, we use an HTTP sink with a simple Python service that writes events to a file.

## Prerequisites

1. Oracle JDBC driver (required for Debezium Oracle connector)
2. Docker images:
   - `oracle/database:21.3.0-xe` (same as OpenLogReplicator tutorial)
   - `quay.io/debezium/server:2.7`

## Setup

### 1. Download Oracle JDBC Driver

```bash
./download-oracle-driver.sh
```

### 2. Create directories with proper permissions

```bash
./init.sh
```

### 3. Start the services

```bash
docker compose up -d
```

### 4. Wait for Oracle to be ready (first run takes several minutes)

```bash
docker logs -f oracle-debezium 2>&1 | grep -m1 "DATABASE IS READY TO USE"
```

### 5. Check Debezium Server logs

```bash
docker logs -f debezium-server
```

### 6. Test: Make changes in Oracle

```bash
docker exec -it oracle-debezium sqlplus USR1/USR1PWD@//localhost:1521/XEPDB1 <<EOF
INSERT INTO ADAM1 VALUES (2, 'Test Row', 200, SYSTIMESTAMP);
COMMIT;
UPDATE ADAM1 SET COUNT = COUNT + 1 WHERE ID = 2;
COMMIT;
DELETE FROM ADAM1 WHERE ID = 2;
COMMIT;
EOF
```

### 7. Check captured events

```bash
cat output/events.json
```

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐     ┌──────────┐
│   Oracle    │────▶│ Debezium Server  │────▶│ File Writer │────▶│  File    │
│  (LogMiner) │     │  (HTTP Sink)     │     │  (Python)   │     │ (JSON)   │
└─────────────┘     └──────────────────┘     └─────────────┘     └──────────┘
```

## Cleanup

```bash
docker compose down -v
rm -rf oradata fra data output/*.json
```
