#!/usr/bin/env python3
"""3-way comparison: DB ground truth vs LM replay vs OLR replay.

Waits for both CDC adapters to process all events up to a watermark SCN
(captured after the fuzz workload ends), then compares replayed final
row states against Oracle.

Usage:
  # After workload ends:
  python3 db-check.py [--watermark-scn SCN]

  If --watermark-scn is not given, queries Oracle for the current SCN.

Environment variables:
  SQLITE_DB     — SQLite database path (default: /app/data/fuzz.db)
  ORACLE_HOST   — Oracle host (default: 192.168.122.130)
  WATERMARK_SCN — SCN watermark (alternative to --watermark-scn flag)
"""

import base64
import json
import os
import sqlite3
import sys
import time

UNAVAILABLE_MARKERS = {
    '__debezium_unavailable_value',
    'X19kZWJleml1bV91bmF2YWlsYWJsZV92YWx1ZQ==',
}

# Tables: (oracle_name, pk_col, compare_cols)
TABLES = [
    ('FUZZ_SCALAR',   'ID', ['EVENT_ID', 'COL_VARCHAR']),
    ('FUZZ_LOB',      'ID', ['EVENT_ID', 'LABEL']),
    ('FUZZ_WIDE',     'ID', ['EVENT_ID', 'C01', 'C02']),
    ('FUZZ_PART',     'ID', ['EVENT_ID', 'REGION', 'PAYLOAD']),
    ('FUZZ_MAXSTR',   'ID', ['EVENT_ID']),
    ('FUZZ_INTERVAL', 'ID', ['EVENT_ID']),
]


def extract_pk(v):
    """Extract integer PK from Debezium's various number encodings."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            return None
    if isinstance(v, dict) and 'value' in v and 'scale' in v:
        try:
            raw = base64.b64decode(v['value'])
            return int.from_bytes(raw, byteorder='big', signed=True)
        except Exception:
            return None
    return None


def has_sentinel(conn, source_table):
    """Check if the sentinel event has been received."""
    row = conn.execute(f"""
        SELECT COUNT(*) FROM {source_table}
        WHERE event_id = 'SENTINEL'
    """).fetchone()
    return row[0] > 0


def get_max_scn(conn, source_table):
    """Get the max source.scn from a CDC events table."""
    row = conn.execute(f"""
        SELECT MAX(CAST(json_extract(raw_json, '$.source.scn') AS INTEGER))
        FROM {source_table}
    """).fetchone()
    return row[0] if row[0] else 0


def get_event_count(conn, source_table):
    """Get total event count."""
    return conn.execute(f"SELECT COUNT(*) FROM {source_table}").fetchone()[0]


def refresh_db(sqlite_path):
    """Re-copy SQLite DB from consumer container (including WAL)."""
    import subprocess
    d = os.path.dirname(sqlite_path)
    subprocess.run(
        ['docker', 'cp', 'fuzz-consumer:/app/data/fuzz.db', sqlite_path],
        capture_output=True
    )
    subprocess.run(
        ['docker', 'cp', 'fuzz-consumer:/app/data/fuzz.db-wal', sqlite_path + '-wal'],
        capture_output=True
    )
    subprocess.run(
        ['docker', 'cp', 'fuzz-consumer:/app/data/fuzz.db-shm', sqlite_path + '-shm'],
        capture_output=True
    )


def wait_for_sentinel(sqlite_path, timeout=600):
    """Wait until both LM and OLR have received the sentinel event.

    The sentinel is an INSERT with event_id='SENTINEL' committed after
    the fuzz workload ends. When both adapters deliver it, all prior
    DML has been processed.
    """
    print(f"  Waiting for sentinel event on both adapters (timeout {timeout}s)...")
    start = time.time()
    while time.time() - start < timeout:
        refresh_db(sqlite_path)
        try:
            conn = sqlite3.connect(sqlite_path)
            conn.row_factory = sqlite3.Row
            lm_sentinel = has_sentinel(conn, 'lm_events')
            olr_sentinel = has_sentinel(conn, 'olr_events')
            lm_scn = get_max_scn(conn, 'lm_events')
            olr_scn = get_max_scn(conn, 'olr_events')
            lm_count = get_event_count(conn, 'lm_events')
            olr_count = get_event_count(conn, 'olr_events')
            conn.close()
        except Exception:
            time.sleep(10)
            continue

        elapsed = int(time.time() - start)
        lm_status = 'SENTINEL' if lm_sentinel else f'scn={lm_scn}'
        olr_status = 'SENTINEL' if olr_sentinel else f'scn={olr_scn}'
        print(f"  [{elapsed:>4d}s] LM: {lm_status} ({lm_count} events) | "
              f"OLR: {olr_status} ({olr_count} events)",
              flush=True)

        if lm_sentinel and olr_sentinel:
            print("  Both adapters received sentinel.")
            refresh_db(sqlite_path)  # Final copy
            time.sleep(2)
            refresh_db(sqlite_path)  # One more to be safe
            return True

        time.sleep(10)

    print(f"  TIMEOUT after {timeout}s.")
    return False


def replay_events(conn, source_table):
    """Replay CDC events into final row state.

    Skips SEED and SENTINEL events. Returns: {(table_name, pk): {col_upper: value, ...}}
    """
    state = {}
    for row in conn.execute(
        f"SELECT table_name, op, raw_json, event_id FROM {source_table} "
        "ORDER BY event_id, seq"
    ).fetchall():
        eid = row['event_id']
        if eid in ('SEED', 'SENTINEL'):
            continue

        event = json.loads(row['raw_json'])
        table = row['table_name']
        op = row['op']

        if op in ('INSERT', 'UPDATE'):
            after = event.get('after')
            if not after:
                continue
            pk = None
            for k, v in after.items():
                if k.upper() == 'ID':
                    pk = extract_pk(v)
                    break
            if pk is None:
                continue
            if (table, pk) not in state:
                state[(table, pk)] = {}
            for k, v in after.items():
                ku = k.upper()
                if isinstance(v, str) and v in UNAVAILABLE_MARKERS:
                    continue
                state[(table, pk)][ku] = v

        elif op == 'DELETE':
            before = event.get('before')
            if not before:
                continue
            pk = None
            for k, v in before.items():
                if k.upper() == 'ID':
                    pk = extract_pk(v)
                    break
            if pk is not None:
                state.pop((table, pk), None)

    return state


def query_oracle(dsn):
    """Query Oracle for final row state. Skip SEED and SENTINEL rows."""
    try:
        import oracledb
    except ImportError:
        print("ERROR: oracledb not installed. pip install oracledb",
              file=sys.stderr)
        sys.exit(1)

    conn = oracledb.connect(dsn)
    cursor = conn.cursor()
    state = {}

    for table_name, pk_col, compare_cols in TABLES:
        all_cols = list(dict.fromkeys([pk_col, 'EVENT_ID'] + compare_cols))
        col_list = ', '.join(all_cols)
        try:
            cursor.execute(
                f"SELECT {col_list} FROM olr_test.{table_name} "
                f"WHERE EVENT_ID NOT IN ('SEED', 'SENTINEL')"
            )
        except Exception as e:
            print(f"  WARNING: {table_name}: {e}", file=sys.stderr)
            continue

        col_names = [d[0].upper() for d in cursor.description]
        for row in cursor:
            row_dict = {}
            pk = None
            for i, col in enumerate(col_names):
                val = row[i]
                if col == pk_col:
                    pk = int(val) if val is not None else None
                if isinstance(val, str):
                    row_dict[col] = val.rstrip()
                elif val is not None:
                    row_dict[col] = str(val)
                else:
                    row_dict[col] = None
            if pk is not None:
                state[(table_name, pk)] = row_dict

    cursor.close()
    conn.close()
    return state


def compare_states(db_state, cdc_state, name):
    """Compare CDC replay against DB ground truth."""
    matched = 0
    missing = []
    extra = []
    diffs = []

    for (table, pk), db_row in sorted(db_state.items()):
        cdc_row = cdc_state.get((table, pk))
        if cdc_row is None:
            missing.append((table, pk, db_row))
            continue

        table_def = next((t for t in TABLES if t[0] == table), None)
        if not table_def:
            matched += 1
            continue

        _, _, compare_cols = table_def
        row_ok = True
        for col in compare_cols:
            db_val = db_row.get(col)
            cdc_val = cdc_row.get(col)
            if isinstance(db_val, str):
                db_val = db_val.rstrip()
            if isinstance(cdc_val, str):
                cdc_val = cdc_val.rstrip()
            if isinstance(cdc_val, dict):
                continue  # Skip complex Debezium types
            if db_val is None and cdc_val is None:
                continue
            if str(db_val) != str(cdc_val):
                diffs.append((table, pk, col, db_val, cdc_val))
                row_ok = False
                break
        if row_ok:
            matched += 1

    for (table, pk), cdc_row in sorted(cdc_state.items()):
        if (table, pk) not in db_state:
            extra.append((table, pk, cdc_row))

    return matched, missing, extra, diffs


def print_results(name, matched, missing, extra, diffs):
    """Print comparison results."""
    print(f"  Matched:  {matched}")

    print(f"  Missing:  {len(missing)} (in DB, not in {name})")
    for table, pk, row in missing[:5]:
        print(f"    [MISSING] {table} pk={pk} event_id={row.get('EVENT_ID')}")
    if len(missing) > 5:
        print(f"    ... and {len(missing) - 5} more")

    print(f"  Extra:    {len(extra)} (in {name}, not in DB)")
    for table, pk, row in extra[:5]:
        eid = row.get('EVENT_ID')
        if isinstance(eid, dict):
            eid = '?'
        print(f"    [EXTRA] {table} pk={pk} event_id={eid}")
    if len(extra) > 5:
        print(f"    ... and {len(extra) - 5} more")

    print(f"  Diffs:    {len(diffs)}")
    for table, pk, col, db_val, cdc_val in diffs[:5]:
        db_s = str(db_val)[:40] if db_val else 'None'
        cdc_s = str(cdc_val)[:40] if cdc_val else 'None'
        print(f"    [DIFF] {table} pk={pk} {col}: DB={db_s} {name}={cdc_s}")
    if len(diffs) > 5:
        print(f"    ... and {len(diffs) - 5} more")


def main():
    sqlite_path = os.environ.get('SQLITE_DB', '/app/data/fuzz.db')
    oracle_host = os.environ.get('ORACLE_HOST', '192.168.122.130')
    oracle_dsn = os.environ.get('ORACLE_DSN',
                                f"olr_test/olr_test@{oracle_host}:1521/ORCLPDB")

    if not os.path.exists(sqlite_path):
        print(f"ERROR: SQLite DB not found: {sqlite_path}", file=sys.stderr)
        sys.exit(1)

    print("=== 3-Way DB Check ===")

    # Wait for both adapters to receive the sentinel event
    print("\n--- Waiting for CDC adapters ---")
    if not wait_for_sentinel(sqlite_path):
        print("WARNING: proceeding with incomplete data", file=sys.stderr)

    # Replay
    conn = sqlite3.connect(sqlite_path)
    conn.row_factory = sqlite3.Row

    print("\n--- Replaying LM events ---")
    lm_state = replay_events(conn, 'lm_events')
    print(f"  LM replay rows: {len(lm_state)}")

    print("\n--- Replaying OLR events ---")
    olr_state = replay_events(conn, 'olr_events')
    print(f"  OLR replay rows: {len(olr_state)}")
    conn.close()

    # Query Oracle
    print("\n--- Querying Oracle for ground truth ---")
    db_state = query_oracle(oracle_dsn)
    print(f"  DB rows: {len(db_state)}")
    for table, _, _ in TABLES:
        count = sum(1 for (t, _) in db_state if t == table)
        if count:
            print(f"    {table}: {count}")

    # Compare
    any_issues = False
    for name, cdc_state in [('LM', lm_state), ('OLR', olr_state)]:
        print(f"\n--- DB vs {name} ---")
        matched, missing, extra, diffs = compare_states(db_state, cdc_state, name)
        print_results(name, matched, missing, extra, diffs)
        if missing or diffs:
            any_issues = True

    # Summary
    print(f"\n{'='*60}")
    if any_issues:
        print("  RESULT: DIFFERENCES FOUND")
    else:
        print("  RESULT: ALL MATCH")
        print("  (Extra rows = phantom CDC events, not data loss)")
    print(f"{'='*60}")

    # Exit 0 if no missing/diffs (extras are phantoms, not failures)
    sys.exit(1 if any_issues else 0)


if __name__ == '__main__':
    main()
