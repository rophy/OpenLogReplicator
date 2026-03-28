# Fuzz Test Framework — Implementation Plan

## Goal

Replace the existing soak test infrastructure with a streaming, component-based
fuzz test framework that validates OLR data accuracy under randomized workloads
over arbitrarily long periods.

## Architecture

```
Oracle RAC (2 nodes)
  └─ PL/SQL fuzz workload (event_id in every row)
       ├─ LogMiner adapter ─→ Kafka topic: lm-events
       └─ OLR adapter      ─→ Kafka topic: olr-events
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

### 1. Load Generator — `fuzz-workload.sql`

- 7 table types: SCALAR, WIDE, LOB, PART, NOPK, MAXSTR, INTERVAL
- `event_id VARCHAR2(30)` on every table — globally unique per CDC event
- Format: `N{node}_{seq:08d}` (e.g., `N1_00000042`)
  - Global monotonic sequence per node — sorts chronologically
  - Table type derivable from CDC event's `source.table`, not encoded in event_id
- Seed data uses `event_id='SEED'` (skipped by consumer)
- Every INSERT generates a new event_id
- Every UPDATE sets a new event_id on the row
- DELETE uses the existing event_id on the row (from before-image)
- Transaction patterns: 55% immediate, 15% batched, 10% rollback, 10% savepoint, 10% large
- 0.5s throttle per transaction to avoid overwhelming OLR

### 2. Kafka — Single broker, KRaft mode

- Image: `apache/kafka:3.9.0`
- No ZooKeeper, `KAFKA_LOG_RETENTION_HOURS: 1`
- Port-mapped (not host network) — `ports: 9092:9092`
- Auto-create topics, 2 topics: `lm-events`, `olr-events`

### 3. Debezium Server — Two instances (existing, reconfigured)

- Switch from HTTP sink to Kafka sink
- Config files: `application-logminer-kafka.properties`, `application-olr-kafka.properties`
- Host network mode (needs access to RAC VM and Kafka via localhost)

### 4. Kafka Consumer — `kafka-consumer.py`

- Single Python process, subscribes to both topics (`lm-events`, `olr-events`)
- Waits for topics to appear before subscribing (handles startup ordering)
- Extracts `event_id` from Debezium JSON (`after.EVENT_ID` or `before.EVENT_ID`)
- Skips events with `event_id='SEED'` or from `FUZZ_STATS` table
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
- Dependency: `kafka-python-ng` (pre-installed in consumer Docker image)

### 5. Validator — `validator.py`

- Continuously polls SQLite, walks both tables in sorted event_id order
- Uses per-node watermark cursors: for each RAC node, validates up to `min(max_lm_event_id, max_olr_event_id)`
- For each event_id:
  - Present in both → check table/op match, merge LOB splits, compare JSON values
  - Present in one only → missing/extra record
- LOB table events (`FUZZ_LOB`) classified as `lob_known` (known bugs olr#26, olr#10)
- Non-LOB mismatches counted as `mismatches` (unexpected)
- JSON comparison: normalize values, handle LOB unavailable markers, timezone formats
- Reports progress every `POLL_INTERVAL` seconds (default: 10)
- Exits after `IDLE_TIMEOUT` seconds of no new events (default: 120)
- Exit 0 = no unexpected mismatches, exit 1 = unexpected mismatches found
- Full log saved to `/tmp/fuzz-validator-*.log` for troubleshooting

### 6. Orchestrator — `fuzz-test.sh`

Stages:
1. Verify prerequisites (RAC VM reachable)
2. Deploy fuzz-workload.sql to RAC (creates tables + PL/SQL package)
3. Start infrastructure (Kafka, Debezium, consumer, validator, OLR)
4. Run fuzz workload on both nodes concurrently
5. Wait for pipeline drain (validator idle-timeout)
6. Report results (accuracy = pass/fail, memory = observation)

## Files

### Created

| File | Purpose |
|------|---------|
| `tests/dbz-twin/rac/fuzz-test.sh` | Orchestrator |
| `tests/dbz-twin/rac/kafka-consumer.py` | Kafka → SQLite bridge |
| `tests/dbz-twin/rac/validator.py` | Continuous comparator |
| `tests/dbz-twin/rac/docker-compose-fuzz.yaml` | Kafka + consumer + validator + Debezium |
| `tests/dbz-twin/rac/config/application-logminer-kafka.properties` | Debezium LogMiner Kafka config |
| `tests/dbz-twin/rac/config/application-olr-kafka.properties` | Debezium OLR Kafka config |
| `tests/dbz-twin/rac/perf/fuzz-workload.sql` | PL/SQL fuzz workload with event_id |
| `tests/design/FUZZ-TEST-PLAN.md` | This plan |

### To Remove (after long-run validation)

| File | Replaced By |
|------|-------------|
| `tests/dbz-twin/rac/soak-test.sh` | `fuzz-test.sh` |
| `tests/dbz-twin/debezium-receiver.py` | `kafka-consumer.py` |
| `tests/dbz-twin/compare-debezium.py` | `validator.py` |

**NOTE:** The HTTP receiver and compare script are also used by the single-instance
twin-test (`tests/dbz-twin/run.sh`) and scenario tests. Those must be migrated
or kept alongside. Evaluate after RAC fuzz test is validated long-term.

## Implementation Order

```
Phase 1: fuzz-workload.sql — add event_id                    ✅ Done
Phase 2: Kafka + Debezium configs (docker-compose-fuzz.yaml) ✅ Done
Phase 3: kafka-consumer.py                                   ✅ Done
Phase 4: validator.py                                        ✅ Done
Phase 5: fuzz-test.sh                                        ✅ Done
Phase 6: Validate with 5-min run                             ✅ Done (0 non-LOB mismatches)
Phase 7: Long-run validation (60+ min)                        ⬜ Pending
Phase 8: Remove old soak-test.sh, receiver, compare scripts   ⬜ Pending
```

## Current Findings

Initial 5-minute fuzz test results showed ~1% non-LOB phantom events.
After investigation and fixes, subsequent runs show **0 non-LOB mismatches**.
LOB known issues (olr#26 + olr#10 variant) remain expected.

## Key Design Decisions

- **event_id is globally unique** — comparison is set-based, not order-based
- **Global monotonic sequence** — event_id sorts chronologically, enabling sorted walk
- **Store raw Debezium JSON** — normalize at comparison time to avoid ingest bugs
- **LOB tables included** — known bugs classified separately, don't fail the test
- **SQLite** — row-oriented PK lookups + sorted range scans = B-tree sweet spot
- **Validator runs continuously** — catch mismatches during the run, not just at the end
- **Accuracy is pass/fail, memory is observation** — this is a fuzz test, not a soak test
