# Fuzz Test — OLR Accuracy Validation

Validates OLR data accuracy under randomized workloads on Oracle RAC by
comparing OLR's CDC output against LogMiner event-by-event.

## Quick Start

```bash
cd tests/dbz-twin/rac

./fuzz-test.sh up           # start infrastructure
./fuzz-test.sh run 60       # run 60-minute workload
./fuzz-test.sh validate     # compare results
./fuzz-test.sh down         # clean up
```

## Architecture

```
Oracle RAC (2 nodes)
  └─ PL/SQL fuzz workload (random DML, event_id on every row)
       ├─ Debezium LogMiner adapter ─→ Kafka topic: lm-events
       └─ Debezium OLR adapter      ─→ Kafka topic: olr-events
                                              │
                                     Python Kafka consumer
                                              │
                                     SQLite (lm_events + olr_events)
                                              │
                                     Python validator
                                     Compares by event_id
```

Both Debezium adapters read from the same Oracle redo logs. LogMiner is the
reference (Oracle's own CDC). OLR is the system under test. If both produce
the same events for the same DML, OLR is accurate.

## Components

### Load Generator (`perf/fuzz-workload.sql`)

PL/SQL package that generates random DML across 7 table types:

| Table | Tests |
|-------|-------|
| FUZZ_SCALAR | Core types: VARCHAR2, NUMBER, FLOAT, DOUBLE, DATE, TIMESTAMP, RAW |
| FUZZ_WIDE | 40+ columns — multi-block redo records |
| FUZZ_LOB | CLOB + BLOB — LOB redo opcodes, out-of-row storage |
| FUZZ_PART | List-partitioned — data-obj-id resolution |
| FUZZ_NOPK | No primary key — ROWID-based supplemental logging |
| FUZZ_MAXSTR | Two VARCHAR2(4000) — near block-boundary rows |
| FUZZ_INTERVAL | INTERVAL YEAR TO MONTH, DAY TO SECOND |

Transaction patterns:
- 55% immediate commit
- 15% batched commit (2-5 operations)
- 10% full rollback
- 10% savepoint + partial rollback
- 10% large transaction (10-30 operations)

Every row has a globally unique `event_id` column (`N{node}_{seq:08d}`).
This is the key for comparison — no ordering assumptions needed.

### Kafka (single broker, KRaft)

Single topic per adapter (`lm-events`, `olr-events`). All tables routed to
one topic via `RegexRouter` to preserve commit order within each adapter.

### Consumer (`kafka-consumer.py`)

Subscribes to both topics. For each event:
1. Extracts `event_id` from Debezium JSON (`after.EVENT_ID` or `before.EVENT_ID`)
2. Writes to SQLite: `(event_id, seq, table_name, op, raw_json, consumed_at)`
3. Skips `FUZZ_STATS` table and `event_id='SEED'` rows

The `seq` column handles LogMiner's LOB splitting (same event_id, multiple
CDC events). SQLite uses WAL mode for concurrent reads.

### Validator (`validator.py`)

Walks both SQLite tables sorted by event_id using a per-node watermark:

1. For each RAC node (N1, N2): `frontier = min(max_lm_event_id, max_olr_event_id)`
2. Fetch event_ids within each node's frontier
3. For each event_id:
   - In both → compare table, op, column values (with LOB merge)
   - In OLR only → extra (phantom transaction)
   - In LM only → missing from OLR
4. LOB table mismatches classified as known issues (olr#26)
5. Non-LOB mismatches = FAIL

Exit 0 = PASS (no non-LOB mismatches), exit 1 = FAIL.

## Commands

| Command | Description |
|---------|-------------|
| `./fuzz-test.sh up` | Start Kafka, Debezium, consumer, OLR. Deploy fuzz tables. |
| `./fuzz-test.sh run [min]` | Run fuzz workload for N minutes (default: 30) |
| `./fuzz-test.sh status` | Show container status, consumer counts, OLR memory |
| `./fuzz-test.sh validate` | Wait for consumer drain, run validator, report PASS/FAIL |
| `./fuzz-test.sh logs <c>` | Show logs: kafka, logminer, olr, consumer, validator, olr-vm |
| `./fuzz-test.sh down` | Stop all containers and remove volumes |

## Prerequisites

- RAC VM running with Oracle containers started
- OLR dev image built (`make build`)
- OLR image loaded on RAC VM (`podman load`)
- One-time setup done (`./setup.sh` — creates `c##dbzuser` + grants)
- `CREATE PROCEDURE` grant for `olr_test` user (for PL/SQL package)

## Known Issues

- **LOB phantom transactions (olr#26)**: OLR emits entire phantom committed
  transactions on FUZZ_LOB that LogMiner does not see. ~0.1% of LOB events.
  Classified as `lob_known` in validator output — does not fail the test.

- **LOB UPDATE variant (olr#10)**: Occasional LOB UPDATE events present in
  LogMiner but absent from OLR. Same phantom undo root cause.

- Non-LOB tables are **100% accurate** in all testing so far.

## SQLite Schema

```sql
CREATE TABLE lm_events (
    event_id    TEXT NOT NULL,
    seq         INTEGER NOT NULL,   -- 0 normally, >0 for LOB splits
    table_name  TEXT NOT NULL,
    op          TEXT NOT NULL,       -- INSERT, UPDATE, DELETE
    raw_json    TEXT NOT NULL,       -- full Debezium envelope
    consumed_at REAL NOT NULL,
    PRIMARY KEY (event_id, seq)
);
-- olr_events: identical schema
```

The database persists after `down` is called. Query it directly for
investigation:

```bash
docker run --rm -v rac_fuzz-data:/data python:3.12-slim python3 -c "
import sqlite3
conn = sqlite3.connect('/data/fuzz.db')
# Example: find all phantom events
for r in conn.execute('''
    SELECT o.event_id, o.table_name, o.op
    FROM olr_events o LEFT JOIN lm_events l ON o.event_id = l.event_id
    WHERE l.event_id IS NULL ORDER BY o.event_id
''').fetchall():
    print(r)
"
```
