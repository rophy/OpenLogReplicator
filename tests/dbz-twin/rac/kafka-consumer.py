#!/usr/bin/env python3
"""Kafka consumer for fuzz test — reads Debezium CDC events and writes to SQLite.

Subscribes to both LogMiner and OLR Kafka topics, extracts event_id from each
Debezium envelope event, and stores the raw JSON in SQLite for comparison.

Environment variables:
  KAFKA_BOOTSTRAP  — Kafka bootstrap servers (default: localhost:9092)
  SQLITE_DB        — SQLite database path (default: /app/data/fuzz.db)
"""

import json
import os
import re
import sqlite3
import sys
import time

from kafka import KafkaConsumer

KAFKA_BOOTSTRAP = os.environ.get('KAFKA_BOOTSTRAP', 'localhost:9092')
SQLITE_DB = os.environ.get('SQLITE_DB', '/app/data/fuzz.db')

OP_MAP = {'c': 'INSERT', 'u': 'UPDATE', 'd': 'DELETE'}

# Tables to skip (stats/bookkeeping)
SKIP_TABLES = {'FUZZ_STATS'}


def init_db(db_path):
    """Create SQLite database and tables."""
    os.makedirs(os.path.dirname(db_path) or '.', exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS lm_events (
            event_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            table_name TEXT NOT NULL,
            op TEXT NOT NULL,
            raw_json TEXT NOT NULL,
            consumed_at REAL NOT NULL,
            PRIMARY KEY (event_id, seq)
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS olr_events (
            event_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            table_name TEXT NOT NULL,
            op TEXT NOT NULL,
            raw_json TEXT NOT NULL,
            consumed_at REAL NOT NULL,
            PRIMARY KEY (event_id, seq)
        )
    """)
    conn.commit()
    return conn


def extract_event_info(event):
    """Extract (event_id, table, op) from a Debezium envelope event.
    Returns None if the event should be skipped."""
    if not isinstance(event, dict):
        return None

    op_code = event.get('op', '')
    if op_code not in OP_MAP:
        return None

    source = event.get('source', {})
    table = source.get('table', '')
    if not table or table in SKIP_TABLES:
        return None

    op = OP_MAP[op_code]

    # Extract event_id from after (INSERT/UPDATE) or before (DELETE)
    event_id = None
    after = event.get('after')
    if after and isinstance(after, dict):
        event_id = after.get('EVENT_ID') or after.get('event_id')
    if event_id is None:
        before = event.get('before')
        if before and isinstance(before, dict):
            event_id = before.get('EVENT_ID') or before.get('event_id')

    if event_id is None or str(event_id) == 'SEED':
        return None

    return (str(event_id), table, op)


LM_TOPIC = os.environ.get('LM_TOPIC', 'lm-events')
OLR_TOPIC = os.environ.get('OLR_TOPIC', 'olr-events')


def determine_adapter(topic):
    """Determine adapter (logminer or olr) from Kafka topic name."""
    if topic == LM_TOPIC:
        return 'logminer'
    elif topic == OLR_TOPIC:
        return 'olr'
    # Fallback for per-table topics
    if topic.startswith('logminer'):
        return 'logminer'
    elif topic.startswith('olr'):
        return 'olr'
    return None


def main():
    print(f"Kafka consumer starting", flush=True)
    print(f"  Bootstrap: {KAFKA_BOOTSTRAP}", flush=True)
    print(f"  SQLite DB: {SQLITE_DB}", flush=True)

    conn = init_db(SQLITE_DB)

    # Wait for Kafka to be available
    consumer = None
    for attempt in range(30):
        try:
            consumer = KafkaConsumer(
                bootstrap_servers=KAFKA_BOOTSTRAP,
                group_id=f'fuzz-consumer-{int(time.time())}',
                auto_offset_reset='earliest',
                enable_auto_commit=True,
                value_deserializer=lambda m: m.decode('utf-8') if m else None,
                consumer_timeout_ms=5000,
                max_poll_records=500,
            )
            break
        except Exception as e:
            if attempt < 29:
                time.sleep(2)
            else:
                print(f"ERROR: Cannot connect to Kafka: {e}", flush=True)
                sys.exit(1)

    # Wait for topics to appear, then subscribe
    print(f"Waiting for topics: {LM_TOPIC}, {OLR_TOPIC}...", flush=True)
    for attempt in range(60):
        topics = consumer.topics()
        if LM_TOPIC in topics or OLR_TOPIC in topics:
            print(f"  Found topics: {[t for t in (LM_TOPIC, OLR_TOPIC) if t in topics]}", flush=True)
            break
        time.sleep(5)

    consumer.subscribe([LM_TOPIC, OLR_TOPIC])
    # Force metadata refresh
    consumer.poll(timeout_ms=1000)
    print(f"Subscribed to {LM_TOPIC} and {OLR_TOPIC}", flush=True)

    # Track per-event_id sequence numbers for LOB split handling.
    # Periodically trimmed to avoid unbounded growth during long runs.
    lm_seq = {}   # event_id -> next seq
    olr_seq = {}  # event_id -> next seq
    SEQ_TRIM_THRESHOLD = 10000  # Trim when maps exceed this size

    lm_count = 0
    olr_count = 0
    batch = []
    batch_start = time.time()
    last_report = time.time()

    try:
        while True:
            messages = consumer.poll(timeout_ms=1000, max_records=500)

            for tp, records in messages.items():
                for msg in records:
                    if msg.value is None:
                        continue

                    try:
                        event = json.loads(msg.value)
                    except json.JSONDecodeError:
                        continue

                    adapter = determine_adapter(msg.topic)
                    if adapter is None:
                        continue

                    info = extract_event_info(event)
                    if info is None:
                        continue

                    event_id, table, op = info
                    now = time.time()

                    # Determine sequence for LOB split handling
                    seq_map = lm_seq if adapter == 'logminer' else olr_seq
                    seq = seq_map.get(event_id, 0)
                    seq_map[event_id] = seq + 1

                    table_name = 'lm_events' if adapter == 'logminer' else 'olr_events'
                    batch.append((
                        table_name, event_id, seq, table, op,
                        msg.value, now
                    ))

                    if adapter == 'logminer':
                        lm_count += 1
                    else:
                        olr_count += 1

            # Flush batch every 100 records or 1 second
            if batch and (len(batch) >= 100 or time.time() - batch_start > 1.0):
                for tbl, eid, seq, table, op, raw, ts in batch:
                    conn.execute(
                        f"INSERT OR REPLACE INTO {tbl} "
                        "(event_id, seq, table_name, op, raw_json, consumed_at) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        (eid, seq, table, op, raw, ts)
                    )
                conn.commit()
                batch = []
                batch_start = time.time()

            # Trim seq maps to bound memory during long runs.
            # Only seq > 0 matters (LOB splits); most events have seq=0 and
            # can be safely evicted since they won't be seen again.
            for seq_map in (lm_seq, olr_seq):
                if len(seq_map) > SEQ_TRIM_THRESHOLD:
                    # Keep only entries with seq > 0 (active LOB splits)
                    to_delete = [k for k, v in seq_map.items() if v <= 1]
                    for k in to_delete:
                        del seq_map[k]

            # Report progress every 30 seconds
            now = time.time()
            if now - last_report >= 30:
                print(f"[consumer] LM={lm_count} OLR={olr_count} "
                      f"seq_keys_lm={len(lm_seq)} seq_keys_olr={len(olr_seq)}",
                      flush=True)
                last_report = now

    except KeyboardInterrupt:
        pass
    finally:
        # Flush remaining
        if batch:
            for tbl, eid, seq, table, op, raw, ts in batch:
                conn.execute(
                    f"INSERT OR REPLACE INTO {tbl} "
                    "(event_id, seq, table_name, op, raw_json, consumed_at) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (eid, seq, table, op, raw, ts)
                )
            conn.commit()
        conn.close()
        consumer.close()
        print(f"[consumer] Shutdown. Final: LM={lm_count} OLR={olr_count}", flush=True)


if __name__ == '__main__':
    main()
