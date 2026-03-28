# Fuzz Test Framework — Implementation Plan

## Goal

Replace the existing soak test infrastructure with a streaming, component-based
fuzz test framework that validates OLR data accuracy under randomized workloads
over arbitrarily long periods.

## Architecture

```
Oracle RAC (2 nodes)
  └─ PL/SQL fuzz workload (event_id in every row)
       ├─ LogMiner adapter ─→ Kafka topic: logminer.*
       └─ OLR adapter      ─→ Kafka topic: olr.*
                                    │
                              Kafka Consumer (Python)
                                    │
                              SQLite (two tables)
                                    │
                              Validator (Python)
                              Walks both tables by event_id
                              Reports mismatches continuously
```

## Components

### 1. Load Generator — `fuzz-workload.sql` (modify existing)

- Add `event_id VARCHAR2(30)` to all 7 tables
- Format: `N{node}_{table_prefix}_{seq}` (e.g., `N1_S_000042`)
- Globally unique: encodes node_id + table prefix + monotonic sequence
- Every INSERT/UPDATE/DELETE sets event_id so CDC event carries it
- Table prefix mapping: S=SCALAR, W=WIDE, L=LOB, P=PART, K=NOPK, M=MAXSTR, I=INTERVAL

### 2. Kafka — Single broker, KRaft mode

- Image: `apache/kafka:3.9.0`
- No ZooKeeper, `KAFKA_LOG_RETENTION_HOURS: 1`
- Auto-create topics, 2 topic prefixes (logminer.*, olr.*)

### 3. Debezium Server — Two instances (existing, reconfigured)

- Switch from HTTP sink to Kafka sink
- New config files: `application-logminer-kafka.properties`, `application-olr-kafka.properties`

### 4. Kafka Consumer — `kafka-consumer.py`

- Single Python process, subscribes to both topic patterns
- Extracts `event_id` from Debezium JSON (`after.EVENT_ID` or `before.EVENT_ID`)
- Writes to SQLite with two tables:
  ```sql
  CREATE TABLE lm_events (
      event_id TEXT NOT NULL,
      seq INTEGER NOT NULL,     -- handles LogMiner LOB split (multiple events per event_id)
      table_name TEXT NOT NULL,
      op TEXT NOT NULL,
      raw_json TEXT NOT NULL,
      consumed_at REAL NOT NULL,
      PRIMARY KEY (event_id, seq)
  );
  CREATE TABLE olr_events (...same schema...);
  ```
- `(event_id, seq)` PK handles LogMiner LOB splits (same event_id, multiple CDC events)
- Batch commits (every 100 records or 1 second)
- SQLite WAL mode for concurrent reader/writer

### 5. Validator — `validator.py`

- Continuously polls SQLite, walks both tables in sorted event_id order
- Uses watermark cursor: only validates up to `min(max_lm_event_id, max_olr_event_id)`
- For each event_id:
  - Present in both → merge LOB splits if needed, compare JSON payload
  - Present in one only → missing/extra record (flag as mismatch)
- JSON comparison: normalize values, handle LOB unavailable markers, timezone formats
- Reports progress every N seconds
- Exit 0 = all match, exit 1 = unexpected mismatches

### 6. Orchestrator — `fuzz-test.sh`

Stages:
1. Verify prerequisites (RAC VM, Docker, OLR image)
2. Deploy fuzz-workload.sql to RAC
3. Start infrastructure (`docker compose -f docker-compose-fuzz.yaml up -d`)
4. Start OLR on RAC VM
5. Wait for readiness (Kafka, Debezium streaming, OLR processing)
6. Run fuzz workload on both nodes concurrently
7. Monitor progress (validator output + OLR memory)
8. After workload completes, insert sentinel, wait for drain
9. Check validator result
10. Report summary (accuracy = pass/fail, memory = observation)

## Files

### Create

| File | Purpose |
|------|---------|
| `tests/dbz-twin/rac/fuzz-test.sh` | Orchestrator |
| `tests/dbz-twin/rac/kafka-consumer.py` | Kafka → SQLite bridge |
| `tests/dbz-twin/rac/validator.py` | Continuous comparator |
| `tests/dbz-twin/rac/docker-compose-fuzz.yaml` | Kafka + consumer + validator + Debezium |
| `tests/dbz-twin/rac/config/application-logminer-kafka.properties` | Debezium LogMiner Kafka config |
| `tests/dbz-twin/rac/config/application-olr-kafka.properties` | Debezium OLR Kafka config |

### Modify

| File | Change |
|------|--------|
| `tests/dbz-twin/rac/perf/fuzz-workload.sql` | Add event_id to all tables + DML |
| `tests/dbz-twin/rac/.gitignore` | Add `*.db` |
| `tests/dbz-twin/rac/Makefile` | Add fuzz targets |

### Remove (after validation)

| File | Replaced By |
|------|-------------|
| `tests/dbz-twin/rac/soak-test.sh` | `fuzz-test.sh` |
| `tests/dbz-twin/debezium-receiver.py` | `kafka-consumer.py` |
| `tests/dbz-twin/compare-debezium.py` | `validator.py` |

**NOTE:** The HTTP receiver and compare script are also used by the single-instance
twin-test (`tests/dbz-twin/run.sh`). Those must be migrated to the new framework
or kept alongside. Evaluate after RAC fuzz test is validated.

## Implementation Order

```
Phase 1: fuzz-workload.sql — add event_id
Phase 2: Kafka + Debezium configs (docker-compose-fuzz.yaml)
Phase 3: kafka-consumer.py
Phase 4: validator.py
Phase 5: fuzz-test.sh + Makefile
Phase 6: Validate with 5-min + 60-min runs
Phase 7: Remove old soak-test.sh, debezium-receiver.py, compare-debezium.py
```

## Key Design Decisions

- **event_id is globally unique** — comparison is set-based, not order-based
- **Store raw Debezium JSON** — normalize at comparison time to avoid ingest bugs
- **LOB tables included** — known bugs (olr#26, olr#10) will produce expected mismatches
- **SQLite over DuckDB** — row-oriented PK lookups + sorted range scans = B-tree sweet spot
- **Validator runs continuously** — catch mismatches during the run, not just at the end
- **Memory monitoring is secondary** — accuracy is pass/fail, memory is observation
