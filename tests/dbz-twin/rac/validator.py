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
PURGE_TTL_HOURS = int(os.environ.get('PURGE_TTL_HOURS', '24'))
START_CURSOR = os.environ.get('START_CURSOR', '')


def parse_cursor(s):
    """Parse 'N1=event_id,N2=event_id' into dict. Empty input -> empty dict."""
    out = {}
    for part in s.split(','):
        part = part.strip()
        if '=' in part:
            k, v = part.split('=', 1)
            out[k.strip()] = v.strip()
    return out


def format_cursor(d):
    return ','.join(f'{k}={v}' for k, v in sorted(d.items()))

# LOB tables that use final-state replay for comparison.
# With the hybrid setup (OLR for non-LOB + LogMiner for LOB), these tables
# should match exactly. Mismatches are treated as real failures.
LOB_TABLES = {'FUZZ_LOB'}


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
    returns (final_after, row_exists):
      - final_after: the merged column values after all ops, skipping
        unavailable LOB markers (they mean "unchanged", not "null")
      - row_exists: False if the last op is DELETE, True otherwise
    """
    sorted_recs = sorted(records, key=lambda r: r['seq'])
    state = {}
    row_exists = True

    for rec in sorted_recs:
        event = json.loads(rec['raw_json'])
        after = normalize_columns(event.get('after'))
        op = rec['op']

        if op == 'DELETE':
            state = {}
            row_exists = False
        else:
            row_exists = True
            for k, v in after.items():
                if not is_unavailable(v):
                    state[k] = v

    return state, row_exists


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


def purge_old_events(conn, ttl_hours):
    """Delete events older than ttl_hours from both tables. Returns count deleted."""
    cutoff = time.time() - ttl_hours * 3600
    lm_del = conn.execute(
        "DELETE FROM lm_events WHERE consumed_at < ?", (cutoff,)).rowcount
    olr_del = conn.execute(
        "DELETE FROM olr_events WHERE consumed_at < ?", (cutoff,)).rowcount
    if lm_del or olr_del:
        conn.commit()
    return lm_del + olr_del


def validate_cycle(conn, cursor_by_node, safe_frontier, widen=False):
    """Run one validation cycle. Returns (validated, matched, mismatches,
    missing_olr, missing_lm, tail_olr, tail_lm, lm_count, olr_count)."""
    validated = matched = mismatches = 0
    missing_olr = missing_lm = tail_olr = tail_lm = 0

    lm_count = conn.execute("SELECT COUNT(*) FROM lm_events").fetchone()[0]
    olr_count = conn.execute("SELECT COUNT(*) FROM olr_events").fetchone()[0]

    # Find safe frontier per node: min(lm, olr) for each N{x} prefix.
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
        return (0, 0, 0, 0, 0, 0, 0, lm_count, olr_count, node_frontiers)

    if widen:
        # Save safe frontier before widening
        safe_frontier.update(node_frontiers)
        for node_prefix in ('N1', 'N2'):
            lm_n = conn.execute(
                "SELECT MAX(event_id) FROM lm_events WHERE event_id LIKE ?",
                (f'{node_prefix}_%',)).fetchone()[0]
            olr_n = conn.execute(
                "SELECT MAX(event_id) FROM olr_events WHERE event_id LIKE ?",
                (f'{node_prefix}_%',)).fetchone()[0]
            if lm_n or olr_n:
                node_frontiers[node_prefix] = max(lm_n or '', olr_n or '')

    # Check if any node has new events beyond its cursor
    any_new = any(
        nf > cursor_by_node.get(np, '')
        for np, nf in node_frontiers.items()
    )
    if not any_new:
        return (0, 0, 0, 0, 0, 0, 0, lm_count, olr_count, node_frontiers)

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
        is_lob = event_table.split('.')[-1].upper() in LOB_TABLES

        if in_lm and not in_olr:
            missing_olr += 1
            if is_tail:
                tail_lm += 1
            else:
                mismatches += 1
                print(f"[MISSING_OLR] {eid} ({event_table})", flush=True)
            validated += 1
            continue

        if in_olr and not in_lm:
            missing_lm += 1
            if is_tail:
                tail_olr += 1
            else:
                mismatches += 1
                print(f"[EXTRA_OLR] {eid} ({event_table})", flush=True)
            validated += 1
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
            lm_state, lm_exists = replay_final_state(lm_recs)
            olr_state, olr_exists = replay_final_state(olr_recs)

            if lm_exists != olr_exists:
                mismatches += 1
                print(f"[LOB_EXISTENCE] {eid} ({event_table}): "
                      f"LM exists={lm_exists} OLR exists={olr_exists}",
                      flush=True)
                validated += 1
            else:
                diffs = compare_values(lm_state, olr_state,
                                       event_table, 'after')
                if diffs:
                    mismatches += 1
                    print(f"[LOB_VALUE_DIFF] {eid} ({event_table}):",
                          flush=True)
                    for d in diffs[:5]:
                        print(d, flush=True)
                else:
                    matched += 1
                validated += 1
            continue

        # Non-LOB tables: compare per (event_id, seq) directly.
        lm_by_seq = {r['seq']: r for r in lm_recs}
        olr_by_seq = {r['seq']: r for r in olr_recs}
        all_seqs = sorted(set(lm_by_seq.keys()) | set(olr_by_seq.keys()))

        for seq in all_seqs:
            lm_r = lm_by_seq.get(seq)
            olr_r = olr_by_seq.get(seq)

            if lm_r and not olr_r:
                missing_olr += 1
                mismatches += 1
                print(f"[MISSING_OLR] {eid} seq={seq} "
                      f"({lm_r['op']} {lm_r['table_name']})",
                      flush=True)
                validated += 1
                continue

            if olr_r and not lm_r:
                missing_lm += 1
                mismatches += 1
                print(f"[EXTRA_OLR] {eid} seq={seq} "
                      f"({olr_r['op']} {olr_r['table_name']})",
                      flush=True)
                validated += 1
                continue

            # Both have this seq — compare
            if lm_r['table_name'] != olr_r['table_name'] or \
               lm_r['op'] != olr_r['op']:
                mismatches += 1
                print(f"[MISMATCH] {eid} seq={seq}: "
                      f"LM={lm_r['op']} {lm_r['table_name']}, "
                      f"OLR={olr_r['op']} {olr_r['table_name']}",
                      flush=True)
                validated += 1
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
                mismatches += 1
                print(f"[VALUE_DIFF] {eid} seq={seq} "
                      f"({lm_r['op']} {lm_r['table_name']}):",
                      flush=True)
                for d in diffs[:5]:
                    print(d, flush=True)
            else:
                matched += 1

            validated += 1

    # Advance per-node cursors
    for node_prefix, nf in node_frontiers.items():
        cursor_by_node[node_prefix] = nf

    return (validated, matched, mismatches, missing_olr, missing_lm,
            tail_olr, tail_lm, lm_count, olr_count, node_frontiers)


def print_summary(total_validated, total_matched, total_mismatches,
                  total_missing_olr, total_missing_lm,
                  total_tail_olr, total_tail_lm):
    """Print final validation summary and return exit code."""
    print(f"\n{'='*60}", flush=True)
    print(f"  Fuzz Test Validation Summary", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Total validated:    {total_validated}", flush=True)
    print(f"  Matched:            {total_matched}", flush=True)
    print(f"  Mismatches:         {total_mismatches}", flush=True)
    print(f"  Missing from OLR:   {total_missing_olr}", flush=True)
    print(f"  Extra in OLR:       {total_missing_lm}", flush=True)
    if total_tail_olr or total_tail_lm:
        print(f"  Tail (OLR ahead):   {total_tail_olr}", flush=True)
        print(f"  Tail (LM ahead):    {total_tail_lm}", flush=True)

    if total_mismatches > 0:
        print(f"\n  RESULT: FAIL ({total_mismatches} unexpected mismatches)",
              flush=True)
        return 1
    else:
        print("\n  RESULT: PASS", flush=True)
        if total_tail_olr + total_tail_lm > 0:
            print(f"  ({total_tail_olr + total_tail_lm} tail events)", flush=True)
        return 0


def main():
    print(f"Validator starting", flush=True)
    print(f"  SQLite DB: {SQLITE_DB}", flush=True)
    print(f"  Poll interval: {POLL_INTERVAL}s", flush=True)
    print(f"  Idle timeout: {IDLE_TIMEOUT}s", flush=True)
    print(f"  Purge TTL: {PURGE_TTL_HOURS}h", flush=True)

    # Wait for database to exist
    while not os.path.exists(SQLITE_DB):
        time.sleep(2)

    conn = sqlite3.connect(SQLITE_DB, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")

    cursor_by_node = {'N1': '', 'N2': ''}
    seeded = parse_cursor(START_CURSOR)
    for k, v in seeded.items():
        if k in cursor_by_node:
            cursor_by_node[k] = v
    if seeded:
        print(f"[validator] resuming from cursor: "
              f"{format_cursor(cursor_by_node)}", flush=True)
    safe_frontier = dict(cursor_by_node)
    total_validated = 0
    total_matched = 0
    total_mismatches = 0
    total_missing_lm = 0
    total_missing_olr = 0
    total_tail_olr = 0
    total_tail_lm = 0
    last_new_events = time.time()
    prev_lm_count = 0
    prev_olr_count = 0

    # Poll until idle, validate, exit
    try:
        while True:
            time.sleep(POLL_INTERVAL)

            lm_count = conn.execute(
                "SELECT COUNT(*) FROM lm_events").fetchone()[0]
            olr_count = conn.execute(
                "SELECT COUNT(*) FROM olr_events").fetchone()[0]

            if lm_count != prev_lm_count or olr_count != prev_olr_count:
                last_new_events = time.time()
                prev_lm_count = lm_count
                prev_olr_count = olr_count

            # Try a validation cycle (safe frontier only)
            result = validate_cycle(conn, cursor_by_node, safe_frontier)
            (v, m, mm, mo, ml, to_, tl, lmc, oc, nf) = result
            total_validated += v
            total_matched += m
            total_mismatches += mm
            total_missing_olr += mo
            total_missing_lm += ml
            total_tail_olr += to_
            total_tail_lm += tl

            if v > 0:
                # Purge old events after each validation cycle
                purged = purge_old_events(conn, PURGE_TTL_HOURS)
                frontier_str = ','.join(
                    f'{k}={v_}' for k, v_ in sorted(cursor_by_node.items()))
                tail_str = (f" tail_olr={total_tail_olr} tail_lm={total_tail_lm}"
                            if total_tail_olr or total_tail_lm else "")
                purge_str = f" purged={purged}" if purged else ""
                print(f"[validator] validated={total_validated} "
                      f"matched={total_matched} "
                      f"mismatches={total_mismatches} "
                      f"missing_olr={total_missing_olr} "
                      f"extra_olr={total_missing_lm}"
                      f"{tail_str}{purge_str} "
                      f"lm_total={lmc} olr_total={oc} "
                      f"frontier={frontier_str}", flush=True)
            elif time.time() - last_new_events > IDLE_TIMEOUT:
                # Idle timeout — do final widened pass
                print(f"[validator] Idle timeout ({IDLE_TIMEOUT}s). "
                      f"Final validation pass...", flush=True)
                result = validate_cycle(
                    conn, cursor_by_node, safe_frontier, widen=True)
                (v, m, mm, mo, ml, to_, tl, lmc, oc, _) = result
                total_validated += v
                total_matched += m
                total_mismatches += mm
                total_missing_olr += mo
                total_missing_lm += ml
                total_tail_olr += to_
                total_tail_lm += tl
                break

    except KeyboardInterrupt:
        pass
    finally:
        conn.close()

    # Emit resumable cursor for soak loop (safe frontier only — never widened,
    # so late-arriving lagging-side events are re-picked-up next cycle).
    final = safe_frontier if any(safe_frontier.values()) else cursor_by_node
    print(f"[validator] final_cursor={format_cursor(final)}", flush=True)

    rc = print_summary(total_validated, total_matched, total_mismatches,
                       total_missing_olr, total_missing_lm,
                       total_tail_olr, total_tail_lm)
    sys.exit(rc)


if __name__ == '__main__':
    main()
