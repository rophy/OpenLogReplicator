#!/usr/bin/env python3
"""Compare normalized LogMiner output vs OLR JSON output.

Usage: compare.py <logminer-json> <olr-output-json>

Exits 0 on match, 1 on mismatch with diff report.

Comparison strategy:
- Parse OLR JSON lines, skip begin/commit/checkpoint messages
- Map OLR ops: c→INSERT, u→UPDATE, d→DELETE
- Match operations by order within each transaction
- Compare table name and column values (type-aware: "100" == 100)
"""

import json
import re
import sys
from datetime import datetime, timezone

OLR_OP_MAP = {'c': 'INSERT', 'u': 'UPDATE', 'd': 'DELETE'}

# Oracle date/timestamp patterns from LogMiner
ORACLE_TIMESTAMP_RE = re.compile(
    r'^(\d{2})-([A-Z]{3})-(\d{2,4})\s+(\d{1,2})\.(\d{2})\.(\d{2})(?:\.(\d+))?\s*(AM|PM)$',
    re.IGNORECASE
)

ORACLE_DATE_FORMATS = [
    '%d-%b-%y',          # DD-MON-RR: 01-JAN-25
    '%d-%b-%Y',          # DD-MON-RRRR: 01-JAN-2025
    '%Y-%m-%d %H:%M:%S', # YYYY-MM-DD HH24:MI:SS
    '%d-%b-%y %H.%M.%S', # DD-MON-RR HH.MI.SS (Oracle default with time)
]


def normalize_value(v):
    """Normalize a value to string for comparison. None stays None."""
    if v is None:
        return None
    return str(v)


def normalize_columns(d):
    """Normalize a dict of column->value to column->string."""
    if not d or not isinstance(d, dict):
        return {}
    return {k: normalize_value(v) for k, v in d.items()}


def parse_logminer_json(path):
    """Parse logminer2json.py output. One JSON object per line."""
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            records.append({
                'op': obj['op'],
                'owner': obj.get('owner', ''),
                'table': obj.get('table', ''),
                'xid': obj.get('xid', ''),
                'scn': obj.get('scn', ''),
                'before': normalize_columns(obj.get('before')),
                'after': normalize_columns(obj.get('after')),
            })
    return records


def parse_olr_json(path):
    """Parse OLR JSON output. One JSON object per line.
    Each line: {"scn":..., "xid":..., "payload":[{...}]}
    Skip begin/commit/checkpoint messages."""
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            payload = obj.get('payload', [])
            xid = obj.get('xid', '')

            for entry in payload:
                op = entry.get('op', '')
                if op not in OLR_OP_MAP:
                    continue

                schema = entry.get('schema', {})
                owner = schema.get('owner', '')
                table = schema.get('table', '')

                before = normalize_columns(entry.get('before'))
                after = normalize_columns(entry.get('after'))

                records.append({
                    'op': OLR_OP_MAP[op],
                    'owner': owner,
                    'table': table,
                    'xid': xid,
                    'scn': str(obj.get('c_scn', '')),
                    'before': before,
                    'after': after,
                })
    return records


def try_parse_oracle_datetime(s):
    """Try to parse an Oracle date/timestamp string to epoch seconds (UTC).

    Handles:
    - DATE: '15-JUN-25' (date only, midnight)
    - TIMESTAMP: '15-JUN-25 10.30.00.123456 AM' (full timestamp)
    - Various date formats

    Returns (epoch_seconds, is_date_only) or (None, None) on failure.
    """
    s = s.strip()

    # Try TIMESTAMP format: DD-MON-RR HH.MI.SS[.FF] AM/PM
    m = ORACLE_TIMESTAMP_RE.match(s)
    if m:
        day, mon, year, hour, minute, sec, frac, ampm = m.groups()
        hour = int(hour)
        if ampm.upper() == 'PM' and hour != 12:
            hour += 12
        elif ampm.upper() == 'AM' and hour == 12:
            hour = 0
        try:
            dt = datetime.strptime(f"{day}-{mon}-{year}", '%d-%b-%y')
            dt = dt.replace(hour=hour, minute=int(minute), second=int(sec),
                            tzinfo=timezone.utc)
            epoch = dt.timestamp()
            if frac:
                epoch += int(frac) / (10 ** len(frac))
            # Round half-up (not banker's rounding) to match OLR behavior
            return int(epoch + 0.5), False
        except ValueError:
            pass

    # Try date-only formats
    for fmt in ORACLE_DATE_FORMATS:
        try:
            dt = datetime.strptime(s, fmt)
            dt = dt.replace(tzinfo=timezone.utc)
            return int(dt.timestamp()), True
        except ValueError:
            continue

    return None, None


def values_match(lm_val, olr_val):
    """Compare two normalized values with type awareness."""
    if lm_val is None and olr_val is None:
        return True
    if lm_val is None or olr_val is None:
        return False
    # Direct string match
    if lm_val == olr_val:
        return True
    # Try numeric comparison with tolerance for float precision differences
    # (e.g., BINARY_FLOAT: LogMiner='3.1400001E+000', OLR='3.14')
    try:
        lm_f, olr_f = float(lm_val), float(olr_val)
        if lm_f == olr_f:
            return True
        # Relative tolerance for IEEE 754 float/double representation differences
        if lm_f != 0 and abs(lm_f - olr_f) / abs(lm_f) < 1e-6:
            return True
        if olr_f != 0 and abs(lm_f - olr_f) / abs(olr_f) < 1e-6:
            return True
    except (ValueError, TypeError):
        pass
    # Try date/timestamp comparison
    lm_epoch, lm_date_only = try_parse_oracle_datetime(lm_val)
    if lm_epoch is not None:
        try:
            olr_epoch = int(olr_val)
            if lm_date_only:
                # LogMiner DATE format truncates time — compare date portion only
                lm_date = datetime.fromtimestamp(lm_epoch, tz=timezone.utc).date()
                olr_date = datetime.fromtimestamp(olr_epoch, tz=timezone.utc).date()
                if lm_date == olr_date:
                    return True
            else:
                # Full timestamp comparison (exact after rounding fractional seconds)
                if lm_epoch == olr_epoch:
                    return True
        except (ValueError, TypeError):
            pass
    olr_epoch, olr_date_only = try_parse_oracle_datetime(olr_val)
    if olr_epoch is not None:
        try:
            lm_epoch_int = int(lm_val)
            if olr_date_only:
                lm_date = datetime.fromtimestamp(lm_epoch_int, tz=timezone.utc).date()
                olr_date = datetime.fromtimestamp(olr_epoch, tz=timezone.utc).date()
                if lm_date == olr_date:
                    return True
            else:
                if olr_epoch == lm_epoch_int:
                    return True
        except (ValueError, TypeError):
            pass
    # Whitespace normalization: LogMiner extraction replaces CR/LF with spaces,
    # OLR preserves the actual characters. Normalize and retry.
    lm_ws = lm_val.replace('\r\n', ' ').replace('\n', ' ').replace('\r', '')
    olr_ws = olr_val.replace('\r\n', ' ').replace('\n', ' ').replace('\r', '')
    if lm_ws == olr_ws:
        return True
    return False


def columns_match(lm_cols, olr_cols, op=None, section=None):
    """Compare two column dicts.

    For UPDATE 'after': OLR may include supplemental log columns not in LogMiner's
    SQL_REDO SET clause — extra OLR columns are not treated as mismatches.
    For other cases: OLR may omit unchanged columns — missing OLR columns are skipped.
    """
    diffs = []
    all_keys = set(lm_cols.keys()) | set(olr_cols.keys())
    for key in sorted(all_keys):
        lm_val = lm_cols.get(key)
        olr_val = olr_cols.get(key)
        if key not in olr_cols:
            # OLR may omit unchanged columns in before/after — skip
            continue
        if key not in lm_cols:
            # OLR may have columns LogMiner doesn't: supplemental logging adds
            # all columns on UPDATE, and LOB data too large for SQL_REDO is
            # absent from LogMiner output — skip in both cases
            continue
        if not values_match(lm_val, olr_val):
            diffs.append(f"  column {key}: LogMiner={lm_val!r}, OLR={olr_val!r}")
    return diffs


def has_empty_lobs(after):
    """Check if any column value is EMPTY_CLOB() or EMPTY_BLOB()."""
    if not after:
        return False
    return any(v in ('EMPTY_CLOB()', 'EMPTY_BLOB()') for v in after.values() if v)


def normalize_lob_operations(records):
    """Merge LOB-related record sequences in LogMiner output.

    Oracle splits LOB writes into multiple redo records:
    A) INSERT with EMPTY_CLOB()/EMPTY_BLOB() + UPDATE with actual values
    B) UPDATE with EMPTY_CLOB()/EMPTY_BLOB() + UPDATE with actual values
    C) UPDATE(non-LOB cols) + UPDATE(LOB cols) at same SCN (single SQL split)

    Merges these into single records to match OLR's coalesced output.
    After merging, remaining EMPTY_CLOB()/EMPTY_BLOB() values (data too large
    for LogMiner SQL_REDO) are removed from the record.
    """
    result = []
    i = 0
    while i < len(records):
        rec = {
            'op': records[i]['op'],
            'owner': records[i]['owner'],
            'table': records[i]['table'],
            'xid': records[i]['xid'],
            'scn': records[i].get('scn', ''),
            'before': dict(records[i].get('before', {})),
            'after': dict(records[i].get('after', {})),
        }

        while i + 1 < len(records):
            nxt = records[i + 1]
            if nxt['op'] != 'UPDATE' or nxt['xid'] != rec['xid'] or nxt['table'] != rec['table']:
                break

            # Pattern A/B: current has EMPTY_CLOB/EMPTY_BLOB → next fills them
            if has_empty_lobs(rec['after']):
                for col, val in nxt.get('after', {}).items():
                    rec['after'][col] = val
                i += 1
                continue

            # Pattern C: consecutive UPDATEs at same SCN (LOB column split)
            if rec['op'] == 'UPDATE' and rec.get('scn') and rec['scn'] == nxt.get('scn', ''):
                for col, val in nxt.get('after', {}).items():
                    rec['after'][col] = val
                i += 1
                continue

            break

        # Remove EMPTY_CLOB()/EMPTY_BLOB() values that weren't filled
        # (LogMiner couldn't capture the data — too large for SQL_REDO)
        rec['after'] = {k: v for k, v in rec['after'].items()
                        if v not in ('EMPTY_CLOB()', 'EMPTY_BLOB()')}

        result.append(rec)
        i += 1
    return result


def sort_by_scn(records):
    """Sort records by SCN for consistent comparison across RAC threads."""
    def sort_key(r):
        try:
            return int(r.get('scn', '0'))
        except (ValueError, TypeError):
            return 0
    return sorted(records, key=sort_key)


def compare(lm_records, olr_records):
    """Compare LogMiner vs OLR records by SCN order. Returns list of diff strings."""
    lm_records = sort_by_scn(lm_records)
    olr_records = sort_by_scn(olr_records)
    diffs = []

    if len(lm_records) != len(olr_records):
        diffs.append(
            f"Record count mismatch: LogMiner={len(lm_records)}, OLR={len(olr_records)}"
        )

    max_records = max(len(lm_records), len(olr_records))
    for i in range(max_records):
        if i >= len(lm_records):
            diffs.append(f"Record #{i+1}: extra OLR record: {olr_records[i]}")
            continue
        if i >= len(olr_records):
            diffs.append(f"Record #{i+1}: extra LogMiner record: {lm_records[i]}")
            continue

        lm = lm_records[i]
        olr = olr_records[i]

        if lm['op'] != olr['op']:
            diffs.append(f"Record #{i+1}: operation mismatch: LogMiner={lm['op']}, OLR={olr['op']}")
            continue

        if lm['table'] != olr['table']:
            diffs.append(f"Record #{i+1}: table mismatch: LogMiner={lm['table']}, OLR={olr['table']}")

        if lm['op'] in ('INSERT', 'UPDATE'):
            col_diffs = columns_match(lm.get('after', {}), olr.get('after', {}),
                                      op=lm['op'], section='after')
            if col_diffs:
                diffs.append(f"Record #{i+1} ({lm['op']}) 'after' column diffs:")
                diffs.extend(col_diffs)

        if lm['op'] in ('UPDATE', 'DELETE'):
            col_diffs = columns_match(lm.get('before', {}), olr.get('before', {}),
                                      op=lm['op'], section='before')
            if col_diffs:
                diffs.append(f"Record #{i+1} ({lm['op']}) 'before' column diffs:")
                diffs.extend(col_diffs)

    return diffs


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <logminer-json> <olr-output-json>", file=sys.stderr)
        sys.exit(2)

    logminer_path = sys.argv[1]
    olr_path = sys.argv[2]

    lm_records = parse_logminer_json(logminer_path)
    olr_records = parse_olr_json(olr_path)

    lm_records = normalize_lob_operations(lm_records)

    diffs = compare(lm_records, olr_records)

    if diffs:
        print("MISMATCH: LogMiner vs OLR output differs:")
        for d in diffs:
            print(d)
        print(f"\nLogMiner records: {len(lm_records)}")
        print(f"OLR records: {len(olr_records)}")
        sys.exit(1)
    else:
        print(f"MATCH: {len(lm_records)} records verified")
        sys.exit(0)


if __name__ == '__main__':
    main()
