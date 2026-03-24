# Debezium Performance Test: OLR vs LogMiner

## Goal

Compare Debezium CDC throughput and latency when using the **OLR adapter** vs the
**LogMiner adapter**, both running against the same Oracle RAC instance under
sustained DML pressure.

## What We're Measuring

| Metric | Definition | How |
|--------|-----------|-----|
| **Throughput (events/sec)** | Events delivered to HTTP receiver per second | Receiver timestamps each event; compute rate over time windows |
| **End-to-end latency** | Oracle commit → event arrival at receiver | `source.ts_ms` (commit time) vs receiver arrival time |
| **Catch-up time** | Time from connector start to "caught up" (lag < 1s) | Monitor lag over time after cold start with backlog |
| **Sustained lag** | Steady-state lag under continuous pressure | Average latency once caught up |

## Architecture

```
Oracle RAC (2 nodes)
  └── PL/SQL DML generator (DBMS_SCHEDULER jobs on both nodes)
        └── continuous INSERT/UPDATE/DELETE on BENCH table

OLR (on RAC VM)
  └── reads redo logs → TCP → Debezium OLR adapter → HTTP sink → receiver

LogMiner adapter
  └── queries redo via SQL → HTTP sink → receiver

Receiver (Python)
  └── timestamps each event, computes throughput/latency, exposes /metrics
```

## DML Generator

PL/SQL job running inside Oracle on both RAC nodes simultaneously:

- Table: `OLR_TEST.BENCH` (id NUMBER, val VARCHAR2(200), node_id NUMBER, created TIMESTAMP)
- Operations: 70% INSERT, 20% UPDATE, 10% DELETE (realistic CDC mix)
- Target rate: configurable, start with ~500 rows/sec per node (1000 total)
- Commit frequency: every 10-50 rows (variable batch size)
- Duration: configurable (default 5 minutes)

No external tools needed — pure PL/SQL with `DBMS_SCHEDULER`.

## Test Scenarios

### 1. Sustained throughput (primary)
- Start DML generator at steady rate
- Let both adapters run for 5 minutes
- Compare: events/sec, average latency, p95 latency

### 2. Burst + catch-up
- Generate 100K rows with both adapters stopped
- Start both adapters simultaneously
- Measure time to process full backlog

### 3. Scaling test
- Increase DML rate in steps: 500, 1000, 2000, 5000 rows/sec
- Find the throughput ceiling for each adapter

## Receiver Enhancements

Current `debezium-receiver.py` needs:
- Per-event timestamp recording (arrival time)
- Extract `source.ts_ms` from Debezium events for latency calculation
- `/metrics` endpoint returning: event count, events/sec (last 10s window),
  avg latency, p50/p95/p99 latency, per-adapter breakdown
- `/metrics/reset` to clear stats between test runs

## Deliverables

1. `tests/debezium/perf-test.sh` — orchestrates the full benchmark
2. Enhanced `debezium-receiver.py` — adds latency/throughput metrics
3. PL/SQL generator scripts (run inside Oracle, no external tools)
4. Results output: JSON summary + human-readable table

## Prerequisites

- RAC VM running with Oracle operational
- OLR image loaded on VM
- Debezium services (docker-compose) configured
- Both adapters configured to consume from same Oracle PDB

## Open Questions

- Should we test single-instance (Oracle XE) as well, or RAC only?
- Do we need Kafka in the path, or is HTTP sink sufficient for comparison?
- Should the generator run for a fixed duration or fixed row count?
