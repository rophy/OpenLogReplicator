# Continuous Data Validation Framework

## Goal

Run OLR and LogMiner Debezium adapters simultaneously under sustained load,
continuously validate both produce identical events, and stop immediately on
any mismatch — preserving redo logs and event history for replay.

## Architecture

```
Oracle RAC (VM)
  └── OLR container (reads redo → TCP:5000)

Host (docker-compose):
  swingbench       → continuous OLTP load via CMAN (port 1521)
  dbz-logminer     → LogMiner adapter → POST /logminer → receiver
  dbz-olr          → OLR adapter      → POST /olr      → receiver
  receiver         → writes logminer.jsonl + olr.jsonl
  validator        → tails both files, matches events, stops on mismatch
```

## Components

### receiver (existing, no changes needed)
- Writes events to `logminer.jsonl` and `olr.jsonl`
- Provides `/metrics` for throughput/latency monitoring

### swingbench (new container)
- `Dockerfile.swingbench` — eclipse-temurin:21 + Swingbench
- Connects to Oracle via CMAN (`VM_IP:1521`)
- Configurable users and runtime via env vars / command args
- Stopped by validator on mismatch

### validator (new)
- Python script that tails both JSONL files
- Extracts match key: `(table, op, sorted(after_columns))`
- Maintains two multisets (one per adapter)
- Match window: events from one adapter are held for N seconds waiting
  for the matching event from the other adapter
- On timeout (event in one adapter but not the other): MISMATCH → stop
- On content diff (same key but different values): MISMATCH → stop
- On match: remove from both sets, increment match counter
- Logs progress every 10s: matched count, pending LM, pending OLR

### On mismatch:
1. Validator sends `docker stop swingbench` (DML stops)
2. Logs the mismatched events with full detail
3. Redo logs on VM are preserved (no log switch)
4. JSONL files preserved for offline replay
5. Exit with non-zero code

## Docker Compose

```yaml
services:
  receiver:     # existing
  dbz-logminer: # existing
  dbz-olr:      # existing
  swingbench:
    image: swingbench:latest
    network_mode: host
    command: ["-cs", "//VM_IP:1521/ORCLPDB", "-u", "soe", "-p", "soe",
              "-c", "/opt/swingbench/configs/SOE_Server_Side_V2.xml",
              "-uc", "4", "-rt", "99:00.00", "-nc", "-nr", "-s"]
  validator:
    image: python:3.12-slim
    network_mode: host
    volumes:
      - ./output:/app/output:ro
      - /var/run/docker.sock:/var/run/docker.sock
    command: ["python3", "/app/validator.py",
              "--logminer", "/app/output/logminer.jsonl",
              "--olr", "/app/output/olr.jsonl",
              "--match-window", "60"]
```

## Match Key Design

For INSERT: `(table, "c", hash(sorted(after_columns)))`
For UPDATE: `(table, "u", hash(sorted(before_columns)), hash(sorted(after_columns)))`
For DELETE: `(table, "d", hash(sorted(before_columns)))`

Using hash of column values (not full content) keeps memory bounded for
long-running tests. Store full content only for recent unmatched events
(within match window) for mismatch reporting.

## Open Questions

- Match window duration: 60s? 120s? Depends on max lag between adapters.
- Should validator also check event count periodically?
- Memory management for very long runs (hours/days)?
- Should we also validate ordering within the same table/key?
