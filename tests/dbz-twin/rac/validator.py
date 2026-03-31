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


def replay_final_state(records):
    """Replay a sequence of DML ops into a final row state.

    Given ordered records (INSERT, UPDATE, UPDATE, ..., optional DELETE),
    returns (final_after, final_op):
      - final_after: the merged column values after all ops, skipping
        unavailable LOB markers (they mean "unchanged", not "null")
      - final_op: 'DELETE' if the last op is DELETE, else 'UPDATE'/'INSERT'
        (indicates whether the row exists at the end)
    """
    sorted_recs = sorted(records, key=lambda r: r['seq'])
    state = {}
    final_op = None

    for rec in sorted_recs:
        event = json.loads(rec['raw_json'])
        after = normalize_columns(event.get('after'))
        final_op = rec['op']

        if final_op == 'DELETE':
            state = {}  # Row deleted
        else:
            # Apply non-unavailable columns (unavailable = unchanged)
            for k, v in after.items():
                if not is_unavailable(v):
                    state[k] = v

    return state, final_op


def compare_values(lm_cols, olr_cols, table, section='after'):
    """Compare two normalized column dicts. Returns list of diff strings.

    LOB unavailable markers are skipped in both before and after images.
    Oracle LogMiner only includes LOB column values when they are explicitly
    changed by the SQL statement — unchanged LOB columns are emitted as
    __debezium_unavailable_value. This is documented Debezium behavior, not
    a bug. See: KNOWN-LIMITATIONS.md L13.
    """
    diffs = []
    all_keys = set(lm_cols.keys()) | set(olr_cols.keys())
    for key in sorted(all_keys):
        if key in ('EVENT_ID',):
            continue  # Event ID verified separately
        va = lm_cols.get(key)
        vb = olr_cols.get(key)
        if key not in lm_cols or key not in olr_cols:
            continue  # Supplemental logging differences
        if is_unavailable(va) or is_unavailable(vb):
            continue  # LOB unavailable — Oracle/Debezium limitation (L1, L13)
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
    safe_frontier = {}  # Last frontier before idle-timeout widening
    total_validated = 0
    total_matched = 0
    total_mismatches = 0
    total_lob_known = 0  # Known LOB issues (expected)
    total_missing_lm = 0
    total_missing_olr = 0
    total_tail_olr = 0  # OLR ahead of LM at drain time (not a bug)
    total_tail_lm = 0   # LM ahead of OLR at drain time (not a bug)
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
                    # Save safe frontier before widening — events beyond this
                    # are tail lag (OLR or LM ahead), not real mismatches.
                    safe_frontier = dict(node_frontiers)
                    # Widen frontier to max of both sides per node to catch
                    # truly missing events (one side never delivered them).
                    for node_prefix in ('N1', 'N2'):
                        lm_n = conn.execute(
                            "SELECT MAX(event_id) FROM lm_events WHERE event_id LIKE ?",
                            (f'{node_prefix}_%',)).fetchone()[0]
                        olr_n = conn.execute(
                            "SELECT MAX(event_id) FROM olr_events WHERE event_id LIKE ?",
                            (f'{node_prefix}_%',)).fetchone()[0]
                        if lm_n or olr_n:
                            node_frontiers[node_prefix] = max(lm_n or '', olr_n or '')
                    # Re-check if there's anything new with widened frontier
                    any_new = any(
                        nf > cursor_by_node.get(np, '')
                        for np, nf in node_frontiers.items()
                    )
                    if not any_new:
                        break
                    # Fall through to validate the widened range
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

                # Check if this event is beyond the safe frontier (tail lag)
                node_prefix = eid[:2]
                is_tail = (safe_frontier
                           and node_prefix in safe_frontier
                           and eid > safe_frontier[node_prefix])

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
                    if is_tail:
                        total_tail_lm += 1
                    elif is_lob:
                        total_lob_known += 1
                    else:
                        total_mismatches += 1
                        print(f"[MISSING_OLR] {eid} ({event_table})", flush=True)
                    total_validated += 1
                    continue

                if in_olr and not in_lm:
                    total_missing_lm += 1
                    if is_tail:
                        total_tail_olr += 1
                    elif is_lob:
                        total_lob_known += 1
                    else:
                        total_mismatches += 1
                        print(f"[EXTRA_OLR] {eid} ({event_table})", flush=True)
                    total_validated += 1
                    continue

                # Both sides have the event — compare.
                lm_recs = conn.execute(
                    "SELECT * FROM lm_events WHERE event_id = ? ORDER BY seq",
                    (eid,)
                ).fetchall()
                olr_recs = conn.execute(
                    "SELECT * FROM olr_events WHERE event_id = ? ORDER BY seq",
                    (eid,)
                ).fetchall()

                if is_lob:
                    # LOB tables: replay ops into final state, compare end result.
                    # LogMiner merges INSERT + LOB_WRITE into a single record (L2),
                    # and OLR may have extra/fewer intermediate events due to
                    # phantom undo (#15). Comparing final state avoids both issues.
                    lm_state, lm_final_op = replay_final_state(lm_recs)
                    olr_state, olr_final_op = replay_final_state(olr_recs)

                    if lm_final_op != olr_final_op:
                        total_lob_known += 1
                        total_validated += 1
                    else:
                        diffs = compare_values(lm_state, olr_state,
                                               event_table, 'after')
                        if diffs:
                            total_lob_known += 1
                        else:
                            total_matched += 1
                        total_validated += 1
                    continue

                # Non-LOB tables: compare per (event_id, seq) directly.
                # Seq numbers are absolute for non-LOB (no merge/phantom issues).
                lm_by_seq = {r['seq']: r for r in lm_recs}
                olr_by_seq = {r['seq']: r for r in olr_recs}
                all_seqs = sorted(set(lm_by_seq.keys()) | set(olr_by_seq.keys()))

                for seq in all_seqs:
                    lm_r = lm_by_seq.get(seq)
                    olr_r = olr_by_seq.get(seq)

                    if lm_r and not olr_r:
                        total_missing_olr += 1
                        total_mismatches += 1
                        print(f"[MISSING_OLR] {eid} seq={seq} "
                              f"({lm_r['op']} {lm_r['table_name']})",
                              flush=True)
                        total_validated += 1
                        continue

                    if olr_r and not lm_r:
                        total_missing_lm += 1
                        total_mismatches += 1
                        print(f"[EXTRA_OLR] {eid} seq={seq} "
                              f"({olr_r['op']} {olr_r['table_name']})",
                              flush=True)
                        total_validated += 1
                        continue

                    # Both have this seq — compare
                    if lm_r['table_name'] != olr_r['table_name'] or \
                       lm_r['op'] != olr_r['op']:
                        total_mismatches += 1
                        print(f"[MISMATCH] {eid} seq={seq}: "
                              f"LM={lm_r['op']} {lm_r['table_name']}, "
                              f"OLR={olr_r['op']} {olr_r['table_name']}",
                              flush=True)
                        total_validated += 1
                        continue

                    lm_evt = json.loads(lm_r['raw_json'])
                    olr_evt = json.loads(olr_r['raw_json'])
                    lm_after = normalize_columns(lm_evt.get('after'))
                    olr_after = normalize_columns(olr_evt.get('after'))
                    lm_before = normalize_columns(lm_evt.get('before'))
                    olr_before = normalize_columns(olr_evt.get('before'))

                    diffs = compare_values(lm_after, olr_after,
                                           lm_r['table_name'], 'after')
                    diffs.extend(compare_values(lm_before, olr_before,
                                                lm_r['table_name'], 'before'))
                    if diffs:
                        total_mismatches += 1
                        print(f"[VALUE_DIFF] {eid} seq={seq} "
                              f"({lm_r['op']} {lm_r['table_name']}):",
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
            tail_str = (f" tail_olr={total_tail_olr} tail_lm={total_tail_lm}"
                        if total_tail_olr or total_tail_lm else "")
            print(f"[validator] validated={total_validated} matched={total_matched} "
                  f"mismatches={total_mismatches} lob_known={total_lob_known} "
                  f"missing_olr={total_missing_olr} extra_olr={total_missing_lm}"
                  f"{tail_str} "
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
    if total_tail_olr or total_tail_lm:
        print(f"  Tail (OLR ahead):   {total_tail_olr}", flush=True)
        print(f"  Tail (LM ahead):    {total_tail_lm}", flush=True)

    if total_mismatches > 0:
        print(f"\n  RESULT: FAIL ({total_mismatches} unexpected mismatches)",
              flush=True)
        sys.exit(1)
    else:
        print("\n  RESULT: PASS", flush=True)
        qualifiers = []
        if total_lob_known > 0:
            qualifiers.append(f"{total_lob_known} known LOB issues")
        if total_tail_olr + total_tail_lm > 0:
            qualifiers.append(f"{total_tail_olr + total_tail_lm} tail events")
        if qualifiers:
            print(f"  ({', '.join(qualifiers)})", flush=True)
        sys.exit(0)


if __name__ == '__main__':
    main()
