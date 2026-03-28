#!/usr/bin/env python3
"""Continuous validator for fuzz test — compares LogMiner vs OLR events in SQLite.

Walks both lm_events and olr_events tables sorted by event_id, comparing
records one-by-one. Uses a watermark cursor to only validate up to the
minimum of both sides' max event_id (handles lag).

For LOB tables, LogMiner splits events (INSERT + UPDATE for same event_id).
The validator merges these before comparing.

Environment variables:
  SQLITE_DB        — SQLite database path (default: /app/data/fuzz.db)
  POLL_INTERVAL    — Seconds between validation polls (default: 10)
  IDLE_TIMEOUT     — Seconds of no new events before declaring done (default: 120)
"""

import json
import os
import sqlite3
import sys
import time

SQLITE_DB = os.environ.get('SQLITE_DB', '/app/data/fuzz.db')
POLL_INTERVAL = int(os.environ.get('POLL_INTERVAL', '10'))
IDLE_TIMEOUT = int(os.environ.get('IDLE_TIMEOUT', '120'))

# Known LOB phantom transaction issues (olr#26, olr#10)
# These produce expected mismatches — report but don't fail
KNOWN_LOB_TABLES = {'FUZZ_LOB'}


def normalize_value(v):
    """Normalize a value for comparison."""
    if v is None:
        return None
    s = str(v)
    # Timezone normalization: Z == +00:00
    if s.endswith('Z'):
        return s[:-1] + '+00:00'
    return s


def normalize_columns(d):
    """Normalize a dict of column->value to comparable form."""
    if not d or not isinstance(d, dict):
        return {}
    return {k.upper(): normalize_value(v) for k, v in d.items()}


# Debezium's LOB unavailable markers
UNAVAILABLE_MARKERS = {
    '__debezium_unavailable_value',
    'X19kZWJleml1bV91bmF2YWlsYWJsZV92YWx1ZQ==',
}


def is_unavailable(v):
    return v is not None and v in UNAVAILABLE_MARKERS


def merge_lob_records(records):
    """Merge LogMiner LOB split records (same event_id, multiple seq values).
    Returns the merged after/before dicts."""
    if len(records) == 1:
        event = json.loads(records[0]['raw_json'])
        return normalize_columns(event.get('after')), normalize_columns(event.get('before'))

    # Sort by seq, merge after-images progressively
    sorted_recs = sorted(records, key=lambda r: r['seq'])
    merged_after = {}
    first_before = {}

    for i, rec in enumerate(sorted_recs):
        event = json.loads(rec['raw_json'])
        after = normalize_columns(event.get('after'))
        for k, v in after.items():
            merged_after[k] = v
        if i == 0:
            first_before = normalize_columns(event.get('before'))

    return merged_after, first_before


def compare_values(lm_after, olr_after, table):
    """Compare two normalized column dicts. Returns list of diff strings."""
    diffs = []
    all_keys = set(lm_after.keys()) | set(olr_after.keys())
    for key in sorted(all_keys):
        if key in ('EVENT_ID',):
            continue  # Event ID verified separately
        va = lm_after.get(key)
        vb = olr_after.get(key)
        if key not in lm_after or key not in olr_after:
            continue  # Supplemental logging differences
        if is_unavailable(va) or is_unavailable(vb):
            continue  # LOB unavailable markers
        if va != vb:
            diffs.append(f"    {key}: LM={va!r} OLR={vb!r}")
    return diffs


def main():
    print(f"Validator starting", flush=True)
    print(f"  SQLite DB: {SQLITE_DB}", flush=True)
    print(f"  Poll interval: {POLL_INTERVAL}s", flush=True)
    print(f"  Idle timeout: {IDLE_TIMEOUT}s", flush=True)

    # Wait for database to exist
    while not os.path.exists(SQLITE_DB):
        time.sleep(2)

    conn = sqlite3.connect(SQLITE_DB)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")

    cursor_by_node = {'N1': '', 'N2': ''}  # Per-node watermark
    total_validated = 0
    total_matched = 0
    total_mismatches = 0
    total_lob_known = 0  # Known LOB issues (expected)
    total_missing_lm = 0
    total_missing_olr = 0
    last_new_events = time.time()
    prev_lm_count = 0
    prev_olr_count = 0

    try:
        while True:
            time.sleep(POLL_INTERVAL)

            # Get current counts
            lm_count = conn.execute("SELECT COUNT(*) FROM lm_events").fetchone()[0]
            olr_count = conn.execute("SELECT COUNT(*) FROM olr_events").fetchone()[0]

            # Check for new events (idle detection)
            if lm_count != prev_lm_count or olr_count != prev_olr_count:
                last_new_events = time.time()
                prev_lm_count = lm_count
                prev_olr_count = olr_count

            # Find safe frontier per node: min(lm, olr) for each N{x} prefix.
            # Event_ids from two RAC nodes interleave non-monotonically in
            # commit order, so a global frontier would validate events before
            # the other side has delivered them.
            node_frontiers = {}
            for node_prefix in ('N1', 'N2'):
                lm_node_max = conn.execute(
                    "SELECT MAX(event_id) FROM lm_events WHERE event_id LIKE ?",
                    (f'{node_prefix}_%',)).fetchone()[0]
                olr_node_max = conn.execute(
                    "SELECT MAX(event_id) FROM olr_events WHERE event_id LIKE ?",
                    (f'{node_prefix}_%',)).fetchone()[0]
                if lm_node_max and olr_node_max:
                    node_frontiers[node_prefix] = min(lm_node_max, olr_node_max)

            if not node_frontiers:
                continue

            # Check if any node has new events beyond its cursor
            any_new = any(
                nf > cursor_by_node.get(np, '')
                for np, nf in node_frontiers.items()
            )
            if not any_new:
                if time.time() - last_new_events > IDLE_TIMEOUT:
                    print(f"[validator] Idle timeout ({IDLE_TIMEOUT}s). "
                          f"Final validation pass...", flush=True)
                    break
                else:
                    continue

            # Fetch event_ids within each node's safe frontier
            lm_ids = set()
            olr_ids = set()
            for node_prefix, nf in node_frontiers.items():
                node_cursor = cursor_by_node.get(node_prefix, '')
                for r in conn.execute(
                    "SELECT DISTINCT event_id FROM lm_events "
                    "WHERE event_id > ? AND event_id <= ? AND event_id LIKE ?",
                    (node_cursor, nf, f'{node_prefix}_%')).fetchall():
                    lm_ids.add(r['event_id'])
                for r in conn.execute(
                    "SELECT DISTINCT event_id FROM olr_events "
                    "WHERE event_id > ? AND event_id <= ? AND event_id LIKE ?",
                    (node_cursor, nf, f'{node_prefix}_%')).fetchall():
                    olr_ids.add(r['event_id'])

            all_ids = sorted(lm_ids | olr_ids)

            for eid in all_ids:
                in_lm = eid in lm_ids
                in_olr = eid in olr_ids

                # Determine table from whichever side has the event
                if in_lm:
                    tbl_row = conn.execute(
                        "SELECT table_name FROM lm_events WHERE event_id = ? LIMIT 1",
                        (eid,)).fetchone()
                else:
                    tbl_row = conn.execute(
                        "SELECT table_name FROM olr_events WHERE event_id = ? LIMIT 1",
                        (eid,)).fetchone()
                event_table = tbl_row['table_name'] if tbl_row else '?'
                is_lob = event_table in KNOWN_LOB_TABLES

                if in_lm and not in_olr:
                    total_missing_olr += 1
                    if is_lob:
                        total_lob_known += 1
                    else:
                        total_mismatches += 1
                        print(f"[MISSING_OLR] {eid} ({event_table})", flush=True)
                    total_validated += 1
                    continue

                if in_olr and not in_lm:
                    total_missing_lm += 1
                    if is_lob:
                        total_lob_known += 1
                    else:
                        total_mismatches += 1
                        print(f"[EXTRA_OLR] {eid} ({event_table})", flush=True)
                    total_validated += 1
                    continue

                # Both sides have the event — compare
                lm_recs = conn.execute(
                    "SELECT * FROM lm_events WHERE event_id = ? ORDER BY seq",
                    (eid,)
                ).fetchall()
                olr_recs = conn.execute(
                    "SELECT * FROM olr_events WHERE event_id = ? ORDER BY seq",
                    (eid,)
                ).fetchall()

                # Check table and op match
                lm_table = lm_recs[0]['table_name']
                olr_table = olr_recs[0]['table_name']
                lm_op = lm_recs[0]['op']
                olr_op = olr_recs[0]['op']

                if lm_table != olr_table or lm_op != olr_op:
                    total_mismatches += 1
                    print(f"[MISMATCH] {eid}: LM={lm_op} {lm_table}, "
                          f"OLR={olr_op} {olr_table}", flush=True)
                    total_validated += 1
                    continue

                # Merge LOB splits and compare values
                lm_after, lm_before = merge_lob_records(
                    [dict(r) for r in lm_recs])
                olr_after, olr_before = merge_lob_records(
                    [dict(r) for r in olr_recs])

                diffs = compare_values(lm_after, olr_after, lm_table)
                diffs.extend(compare_values(lm_before, olr_before, lm_table))
                if diffs:
                    if is_lob:
                        total_lob_known += 1
                    else:
                        total_mismatches += 1
                        print(f"[VALUE_DIFF] {eid} ({lm_op} {lm_table}):",
                              flush=True)
                        for d in diffs[:5]:
                            print(d, flush=True)
                else:
                    total_matched += 1

                total_validated += 1

            # Advance per-node cursors
            for node_prefix, nf in node_frontiers.items():
                cursor_by_node[node_prefix] = nf

            # Progress report
            frontier_str = ','.join(f'{k}={v}' for k, v in sorted(cursor_by_node.items()))
            print(f"[validator] validated={total_validated} matched={total_matched} "
                  f"mismatches={total_mismatches} lob_known={total_lob_known} "
                  f"missing_olr={total_missing_olr} extra_olr={total_missing_lm} "
                  f"lm_total={lm_count} olr_total={olr_count} "
                  f"frontier={frontier_str}", flush=True)

    except KeyboardInterrupt:
        pass
    finally:
        conn.close()

    # Final summary
    print(f"\n{'='*60}", flush=True)
    print(f"  Fuzz Test Validation Summary", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Total validated:    {total_validated}", flush=True)
    print(f"  Matched:            {total_matched}", flush=True)
    print(f"  Mismatches:         {total_mismatches}", flush=True)
    print(f"  LOB known issues:   {total_lob_known}", flush=True)
    print(f"  Missing from OLR:   {total_missing_olr}", flush=True)
    print(f"  Extra in OLR:       {total_missing_lm}", flush=True)

    if total_mismatches > 0:
        print(f"\n  RESULT: FAIL ({total_mismatches} unexpected mismatches)",
              flush=True)
        sys.exit(1)
    else:
        print(f"\n  RESULT: PASS", flush=True)
        if total_lob_known > 0:
            print(f"  (with {total_lob_known} known LOB issues)", flush=True)
        sys.exit(0)


if __name__ == '__main__':
    main()
