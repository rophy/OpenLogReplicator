# Soak Test Implementation Guide

Upgrade the existing fuzz test into a continuous soak test that runs indefinitely
with 24h TTL-based storage cleanup.

## Current State

The fuzz test runs a finite workload, waits for drain, validates once, then tears down.
Key components already exist:

- `fuzz-test.sh` — orchestration (up/down/run/validate/db-check)
- `kafka-consumer.py` — Kafka → SQLite consumer (infinite loop)
- `validator.py` — per-event comparison with per-node watermarks
- `fuzz-workload.sql` — PL/SQL package generating random DML with event_id tracking
- `docker-compose-fuzz.yaml` — Kafka, Debezium connectors, consumer, validator

## Goal

Run the full pipeline indefinitely:
1. Load generator produces DML at constant rate, non-stop
2. Consumer writes to SQLite non-stop
3. Validator periodically checks data up to a watermark, reports pass/fail, purges old data
4. All storage cleaned up on a 24h TTL
5. Runs forever unless stopped or a failure is detected

## Storage TTL: 24h Everywhere

All transient data uses the same 24h retention window:

| Storage | Current | Change |
|---------|---------|--------|
| Kafka topics | 24h retention | No change needed |
| SQLite events | Grows forever | Purge events older than 24h after validation |
| Archive logs | No cleanup | Cron: `find /shared/redo/archivelog -mtime +1 -delete` |
| Oracle tables | Grows forever | DELETE rows with `created_at < SYSDATE - 1` |

If any component falls behind by more than ~1 hour, treat it as a test failure
and stop the whole setup for investigation. The 24h buffer is deliberately generous.

## Changes Required

### 1. Workload Generator — Infinite Loop

**File**: `perf/fuzz-workload.sql` (FUZZ_WKL package)

Current: `run(p_duration_min NUMBER)` exits after N minutes.

Change: Add `run_forever(p_rate_per_sec NUMBER)` procedure that:
- Runs DML in an infinite loop with pacing (e.g., 10 ops/sec)
- Calls `DBMS_SESSION.SLEEP()` between batches to maintain target rate
- Handles connection drops gracefully (reconnect and continue)
- Periodically logs throughput stats to `FUZZ_STATS` table

**Invocation**: `fuzz-test.sh soak` starts the workload via SSH on both RAC nodes
as background processes. No fixed duration.

### 2. Consumer — Add Timestamp Column

**File**: `kafka-consumer.py`

Current SQLite schema:
```sql
CREATE TABLE lm_events (
    event_id TEXT, seq INTEGER, table_name TEXT, op TEXT,
    raw_json TEXT, consumed_at REAL,
    PRIMARY KEY (event_id, seq)
);
```

`consumed_at` already exists (epoch float). No schema change needed — use it for TTL purge.

**Memory concern**: The `lm_seq` / `olr_seq` dicts track event_id → next seq number
and grow unbounded. Add periodic cleanup: remove entries where the event_id's
`consumed_at` is older than 24h. The comment warns against trimming due to seq reset
bugs — the fix is to only trim entries outside the 24h window (no active events
will reference them).

### 3. Validator — Periodic + Purge Mode

**File**: `validator.py`

Current: Polls until idle (120s no new events), then validates once and exits.

Change to continuous mode:
- Run in an infinite loop with configurable interval (e.g., every 5 minutes)
- Each cycle:
  1. Compute per-node watermarks (same logic as today)
  2. Validate all events up to watermark
  3. Report results: `[SOAK] cycle=42 validated=12345 mismatches=0 elapsed=3.2s`
  4. **Purge**: DELETE from lm_events/olr_events WHERE consumed_at < (now - 24h)
  5. If any non-LOB mismatches found, write failure report and exit non-zero
- Never exit on idle — in soak mode, idle just means the workload is between batches

**New env vars**:
- `SOAK_MODE=1` — enables continuous validation + purge (default: off, preserving current behavior)
- `PURGE_TTL_HOURS=24` — how old events must be before purge
- `VALIDATE_INTERVAL_SEC=300` — seconds between validation cycles

### 4. Archive Log Cleanup (part of `fuzz-test.sh up`)

**Where**: Started as a background job during `fuzz-test.sh up`, not soak-specific.
Useful for any fuzz run — even finite runs leave behind archive logs.

Add to `fuzz-test.sh up` after all services are started:
```bash
# Background archive cleanup every hour (killed on `down`)
while true; do
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "find /shared/redo/archivelog -mtime +1 -delete"
    sleep 3600
done &
echo $! > "$WORK_DIR/archive_cleanup.pid"
```

Kill in `fuzz-test.sh down`:
```bash
[ -f "$WORK_DIR/archive_cleanup.pid" ] && kill "$(cat "$WORK_DIR/archive_cleanup.pid")" 2>/dev/null
```

### 5. Oracle Table Cleanup (part of `fuzz-test.sh up`)

**File**: `perf/fuzz-workload.sql`

Add a `cleanup()` procedure to FUZZ_WKL package:
```sql
PROCEDURE cleanup IS
BEGIN
    FOR t IN (SELECT table_name FROM user_tables
              WHERE table_name LIKE 'FUZZ_%'
              AND table_name != 'FUZZ_STATS') LOOP
        EXECUTE IMMEDIATE 'DELETE FROM ' || t.table_name ||
            ' WHERE created_at < SYSDATE - 1';
        COMMIT;
    END LOOP;
END;
```

**Prerequisite**: Add `created_at DATE DEFAULT SYSDATE` column to all FUZZ_* tables
in the table creation DDL (already in `fuzz-test.sh up`).

Schedule via Oracle DBMS_SCHEDULER job created during `fuzz-test.sh up`:
```sql
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name   => 'FUZZ_CLEANUP',
        job_type   => 'PLSQL_BLOCK',
        job_action => 'BEGIN FUZZ_WKL.cleanup; END;',
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=30',
        enabled    => TRUE
    );
END;
```

Drop in `fuzz-test.sh down` table cleanup.

### 6. New Subcommand: `fuzz-test.sh soak`

Orchestration for the continuous run:

```
fuzz-test.sh soak [rate-per-sec]
```

Steps:
1. Verify all services running (reuse Stage 1 from `run`)
2. Start archive log cleanup loop (background)
3. Start workload on both RAC nodes (background, infinite)
4. Print status line every 60s:
   `[SOAK] uptime=2h13m LM=45230 OLR=45228 validated=44000 mismatches=0`
5. Monitor for failures:
   - Validator exits non-zero → stop everything, print report
   - Consumer dies → stop everything
   - OLR container exits → stop everything
6. On SIGINT/SIGTERM: graceful shutdown (stop workload, drain, final validate)

### 7. Health Monitoring

Add a stall detector — if no new events arrive for 5 minutes, something is broken:

In the validator's continuous loop, track `last_event_time`. If
`now - last_event_time > 300s` while the workload is running, report:
```
[STALL] No new events for 5m. Last LM event: N1_00045230 at 10:15:02. Last OLR event: N1_00045228 at 10:15:01.
```
Then exit non-zero to trigger the soak test shutdown.

## Implementation Order

**Phase A — Cleanup (part of fuzz environment, not soak-specific):**
1. **Add `created_at` column** to FUZZ_* table DDL + Oracle cleanup job (DBMS_SCHEDULER)
2. **Archive log cleanup** — background loop started by `fuzz-test.sh up`
3. **Consumer seq dict cleanup** — prune entries older than 24h
4. **Validator purge** — DELETE validated events older than 24h (enabled by default)

Phase A can be tested with the existing finite workload — just run longer and
verify storage stays bounded.

**Phase B — Soak mode (continuous operation):**
5. **Validator soak mode** — continuous validate-purge loop instead of exit-on-idle
6. **Workload `run_forever`** — infinite loop with rate limiting
7. **`fuzz-test.sh soak`** subcommand — ties everything together
8. **Health monitoring** — stall detection

## Testing the Upgrade

1. Run `fuzz-test.sh soak 5` (5 ops/sec) for 1 hour
2. Verify validator reports pass every 5 minutes
3. Verify SQLite size stays bounded (check after 30min)
4. Verify archive log directory doesn't grow past ~2 GB
5. Verify Oracle tablespace stays bounded
6. Kill OLR mid-run → confirm stall detection fires within 5 minutes
7. Run for 24+ hours → confirm TTL purge works across the full window

## Files to Modify

| File | Change |
|------|--------|
| `fuzz-test.sh` | Add `soak` subcommand |
| `validator.py` | Add SOAK_MODE, continuous loop, purge |
| `kafka-consumer.py` | Add seq dict cleanup for old entries |
| `perf/fuzz-workload.sql` | Add `run_forever()`, `cleanup()`, `created_at` columns |
| `docker-compose-fuzz.yaml` | Add SOAK_MODE env var to validator service |
