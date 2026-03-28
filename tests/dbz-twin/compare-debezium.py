#!/usr/bin/env python3
"""Compare Debezium LogMiner vs OLR adapter outputs.

Usage: compare-debezium.py [--exclude-tables T1,T2,...] <logminer.jsonl> <olr.jsonl>

Both inputs are JSONL files with Debezium envelope events:
  {"before":..., "after":..., "source":..., "op":..., "ts_ms":...}

Uses content-based matching grouped by (txId, table, op) to handle
cross-node ordering differences in RAC. Falls back to positional
comparison within groups.

Exits 0 on match, 1 on mismatch with diff report.
"""

import argparse
import json
import sys
from collections import defaultdict

OP_MAP = {'c': 'INSERT', 'u': 'UPDATE', 'd': 'DELETE'}

# Debezium's marker for LOB columns it can't provide.
# CLOB: literal string; BLOB: base64 encoding of the same string.
UNAVAILABLE_MARKERS = {
    '__debezium_unavailable_value',
    'X19kZWJleml1bV91bmF2YWlsYWJsZV92YWx1ZQ==',
}

# Tables always excluded from comparison (stats/bookkeeping, not test data).
# Additional tables can be excluded via --exclude-tables CLI flag.
EXCLUDED_TABLES = {'FUZZ_STATS'}


def is_unavailable(v):
    """Check if a normalized value is Debezium's unavailable marker."""
    return v is not None and v in UNAVAILABLE_MARKERS


def normalize_value(v):
    """Normalize a value for comparison. None stays None."""
    if v is None:
        return None
    return str(v)


def normalize_columns(d):
    """Normalize a dict of column->value to column->string."""
    if not d or not isinstance(d, dict):
        return {}
    return {k: normalize_value(v) for k, v in d.items()}


def parse_debezium_jsonl(path, excluded_tables=None):
    """Parse a Debezium JSONL file into normalized records."""
    skip_tables = EXCLUDED_TABLES | (excluded_tables or set())
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)

            source = event.get('source', {})
            table = source.get('table', '')
            schema = source.get('schema', '')
            op = event.get('op', '')
            tx_id = source.get('txId', '')

            # Skip non-DML events
            if op not in OP_MAP:
                continue

            # Skip excluded tables
            if table in skip_tables:
                continue

            records.append({
                'op': OP_MAP[op],
                'schema': schema,
                'table': table,
                'txId': tx_id,
                'before': normalize_columns(event.get('before')),
                'after': normalize_columns(event.get('after')),
            })
    return records


def merge_lob_events(records):
    """Merge LogMiner's split LOB events into single logical events.

    LogMiner splits LOB operations into multiple events:
      - INSERT with EMPTY_CLOB/EMPTY_BLOB (nulls) + UPDATE with actual LOB values
      - UPDATE non-LOB columns + UPDATE LOB columns
    OLR emits these as single merged events. This function merges consecutive
    events on the same row so the two outputs become comparable.
    """
    if not records:
        return records

    merged = [dict(records[0])]
    for rec in records[1:]:
        prev = merged[-1]
        if _can_merge_lob(prev, rec):
            merged[-1] = _do_merge(prev, rec)
        else:
            merged.append(dict(rec))
    return merged


def _can_merge_lob(prev, curr):
    """Check if curr is a LOB-split continuation of prev."""
    if prev['table'] != curr['table']:
        return False
    if curr['op'] != 'UPDATE':
        return False
    if prev['op'] not in ('INSERT', 'UPDATE'):
        return False
    return _same_row(prev.get('after', {}), curr.get('after', {}))


def _same_row(a_after, b_after):
    """Check if two after-images refer to the same row via shared key columns."""
    matching = 0
    for k in set(a_after) & set(b_after):
        va, vb = a_after.get(k), b_after.get(k)
        if va is None or vb is None:
            continue
        if is_unavailable(va) or is_unavailable(vb):
            continue
        # Both have real values
        if va == vb:
            matching += 1
        else:
            return False
    return matching > 0


def _merge_columns(prev_cols, curr_cols):
    """Merge column dicts. The later event (curr) always wins because it
    represents the final state of the LOB split — even if curr's value is
    None (LOB set to NULL), it overrides prev's unavailable marker."""
    merged = dict(prev_cols)
    for k, v in curr_cols.items():
        merged[k] = v
    return merged


def _do_merge(prev, curr):
    """Merge curr UPDATE into prev, keeping prev's op type and before."""
    return {
        'op': prev['op'],
        'schema': prev['schema'],
        'table': prev['table'],
        'txId': prev.get('txId', ''),
        'after': _merge_columns(prev.get('after', {}), curr.get('after', {})),
        'before': prev.get('before', {}),
    }


def normalize_tz(s):
    """Normalize timezone representations: 'Z' and '+00:00' are equivalent."""
    if isinstance(s, str):
        # ISO8601: trailing 'Z' is equivalent to '+00:00'
        if s.endswith('Z'):
            return s[:-1] + '+00:00'
    return s


def values_match(a, b):
    """Compare two normalized values with strict equality."""
    if a is None and b is None:
        return True
    if a is None or b is None:
        return False
    if a == b:
        return True
    # Try timezone normalization
    return normalize_tz(a) == normalize_tz(b)


def columns_match(cols_a, cols_b, section='after'):
    """Compare two column dicts. Returns list of diff strings.

    section: 'before' or 'after'. LOB unavailable values are only skipped
    in 'before' images — Oracle LogMiner does not provide old LOB values
    in SQL_UNDO (see KNOWN-LIMITATIONS.md L1). In 'after' images, unavailable
    values indicate a real problem (e.g. lob.enabled=false).
    """
    diffs = []
    all_keys = set(cols_a.keys()) | set(cols_b.keys())
    for key in sorted(all_keys):
        va = cols_a.get(key)
        vb = cols_b.get(key)
        if key not in cols_b or key not in cols_a:
            # One side has extra columns — skip (supplemental logging diffs)
            continue
        if section == 'before' and (is_unavailable(va) or is_unavailable(vb)):
            # LOB before-image unavailable — Oracle doesn't provide old LOB
            # values in redo (L1 in KNOWN-LIMITATIONS.md)
            continue
        if not values_match(va, vb):
            diffs.append(f"  column {key}: LogMiner={va!r}, OLR={vb!r}")
    return diffs


def record_match_score(lm, olr):
    """Score how well two records match. Returns (matches, mismatches).
    Higher matches and lower mismatches = better match."""
    if lm['op'] != olr['op'] or lm['table'] != olr['table']:
        return (0, 999)

    matches = 0
    mismatches = 0

    for section in ('after', 'before'):
        lm_cols = lm.get(section, {})
        olr_cols = olr.get(section, {})
        for key in set(lm_cols) & set(olr_cols):
            va, vb = lm_cols.get(key), olr_cols.get(key)
            if va is None or vb is None:
                continue
            if section == 'before' and (is_unavailable(va) or is_unavailable(vb)):
                continue
            if values_match(va, vb):
                matches += 1
            else:
                mismatches += 1

    return (matches, mismatches)


def match_within_group(group_key, lm_group, olr_group):
    """Content-based matching within a (txId, table, op) group.
    Returns list of diff strings."""
    diffs = []

    if len(lm_group) != len(olr_group):
        diffs.append(
            f"Group {group_key}: count mismatch "
            f"LogMiner={len(lm_group)}, OLR={len(olr_group)}"
        )

    # Greedy best-match: for each LM record, find best OLR match
    available = list(range(len(olr_group)))
    matched_pairs = []

    for li, lm in enumerate(lm_group):
        best_idx = None
        best_score = (0, 999)
        for ai, oi in enumerate(available):
            score = record_match_score(lm, olr_group[oi])
            # Better = more matches, fewer mismatches
            if (score[1] < best_score[1]) or \
               (score[1] == best_score[1] and score[0] > best_score[0]):
                best_score = score
                best_idx = ai
        if best_idx is not None:
            matched_pairs.append((li, available.pop(best_idx)))
        else:
            diffs.append(f"Group {group_key}: LM record {li} has no OLR match")

    # Report diffs for matched pairs
    for li, oi in matched_pairs:
        lm = lm_group[li]
        olr = olr_group[oi]

        if lm['op'] in ('INSERT', 'UPDATE'):
            cd = columns_match(
                lm.get('after', {}), olr.get('after', {}), section='after')
            if cd:
                diffs.append(
                    f"Group {group_key} ({lm['op']} {lm['table']}) 'after' diffs:")
                diffs.extend(cd)

        if lm['op'] in ('UPDATE', 'DELETE'):
            cd = columns_match(
                lm.get('before', {}), olr.get('before', {}), section='before')
            if cd:
                diffs.append(
                    f"Group {group_key} ({lm['op']} {lm['table']}) 'before' diffs:")
                diffs.extend(cd)

    # Unmatched OLR records
    for oi in available:
        diffs.append(
            f"Group {group_key}: extra OLR record "
            f"({olr_group[oi]['op']} {olr_group[oi]['table']})")

    return diffs


def compare(lm_records, olr_records):
    """Compare LogMiner vs OLR records using content-based matching."""
    diffs = []

    if len(lm_records) != len(olr_records):
        diffs.append(
            f"Record count mismatch: LogMiner={len(lm_records)}, "
            f"OLR={len(olr_records)}"
        )

    # Group by (txId, table, op)
    lm_groups = defaultdict(list)
    olr_groups = defaultdict(list)
    for r in lm_records:
        key = (r.get('txId', ''), r['table'], r['op'])
        lm_groups[key].append(r)
    for r in olr_records:
        key = (r.get('txId', ''), r['table'], r['op'])
        olr_groups[key].append(r)

    all_keys = sorted(set(lm_groups.keys()) | set(olr_groups.keys()))

    for key in all_keys:
        lm_group = lm_groups.get(key, [])
        olr_group = olr_groups.get(key, [])

        if not lm_group and olr_group:
            diffs.append(
                f"Group {key}: {len(olr_group)} extra OLR records "
                f"(no LogMiner match)")
            continue
        if lm_group and not olr_group:
            diffs.append(
                f"Group {key}: {len(lm_group)} LogMiner records "
                f"missing from OLR")
            continue

        group_diffs = match_within_group(key, lm_group, olr_group)
        diffs.extend(group_diffs)

    return diffs


def main():
    parser = argparse.ArgumentParser(
        description='Compare Debezium LogMiner vs OLR adapter outputs.')
    parser.add_argument('logminer_jsonl', help='LogMiner JSONL file')
    parser.add_argument('olr_jsonl', help='OLR JSONL file')
    parser.add_argument('--exclude-tables', default='',
                        help='Comma-separated list of additional tables to exclude')
    args = parser.parse_args()

    extra_excluded = set(t.strip() for t in args.exclude_tables.split(',') if t.strip())

    lm_records = parse_debezium_jsonl(args.logminer_jsonl, extra_excluded)
    olr_records = parse_debezium_jsonl(args.olr_jsonl, extra_excluded)

    # Merge LogMiner's split LOB events (OLR already emits merged events)
    lm_merged = merge_lob_events(lm_records)
    olr_merged = merge_lob_events(olr_records)

    diffs = compare(lm_merged, olr_merged)

    if diffs:
        print("MISMATCH: LogMiner vs OLR Debezium output differs:")
        for d in diffs:
            print(d)
        print(f"\nLogMiner records: {len(lm_merged)} (raw: {len(lm_records)})")
        print(f"OLR records: {len(olr_merged)} (raw: {len(olr_records)})")
        sys.exit(1)
    else:
        print(f"MATCH: {len(lm_merged)} records verified "
              f"(LogMiner raw: {len(lm_records)}, OLR raw: {len(olr_records)})")
        sys.exit(0)


if __name__ == '__main__':
    main()
