# LogMiner vs OLR: Known Behavioral Differences

This document catalogs the known differences between Oracle LogMiner and
OpenLogReplicator (OLR) CDC output. Both tools read Oracle redo logs, but they
operate at different levels and produce structurally different event streams for
the same SQL operations.

These differences affect any system that compares or consumes output from both
sources — including the test comparison scripts in this repository:

- `tests/sql/scripts/compare.py` — fixture generator (raw JSON comparison)
- `tests/dbz-twin/compare-debezium.py` — Debezium twin-test (Kafka Connect envelope comparison)

---

## 1. LOB Operation Splitting

**LogMiner** exposes Oracle's internal two-step LOB storage mechanism as
separate events. **OLR** reconstructs the logical operation from redo records
and emits a single merged event.

### Example: `INSERT INTO t VALUES (1, 'CLOB text', HEXTORAW('AABB'))`

| # | LogMiner | OLR |
|---|----------|-----|
| 1 | INSERT: id=1, col_clob=EMPTY_CLOB(), col_blob=EMPTY_BLOB() | INSERT: id=1, col_clob='CLOB text', col_blob=AABB |
| 2 | UPDATE: id=1, col_clob='CLOB text', col_blob=AABB | *(no second event)* |

This applies to all LOB types (CLOB, BLOB, NCLOB) and all operations:

- **INSERT with LOBs**: LogMiner emits INSERT(empty) + UPDATE(actual). OLR
  emits one INSERT with final values.
- **UPDATE with LOBs**: LogMiner may emit UPDATE(non-LOB columns) +
  UPDATE(LOB columns) at the same SCN. OLR emits one UPDATE.
- **NULL LOB INSERT**: Even `INSERT ... VALUES (1, NULL, NULL)` on a table
  with LOB columns produces INSERT + UPDATE in LogMiner (the UPDATE is a
  no-op). OLR emits just the INSERT.

### Large LOBs

For out-of-row LOBs (typically >4000 bytes), LogMiner's `SQL_REDO` cannot
represent the full value. It outputs `EMPTY_CLOB()`/`EMPTY_BLOB()` with no
follow-up UPDATE containing the data. OLR reads the LOB data directly from
redo and provides the full content.

In the Debezium pipeline, this surfaces as `__debezium_unavailable_value` for
LOB columns that LogMiner cannot provide.

### Why OLR merges

OLR processes raw redo log records, not reconstructed SQL. Oracle writes
multi-piece operations (INSERT + LOB fill) as consecutive redo records within
the same transaction. OLR's `Transaction::flush()` accumulates records for the
same row (matching `suppLogBdba` + `suppLogSlot` + `obj`) and calls
`processDml()` once when it sees the last-fragment flag (`FB_L`). There is no
configuration option to disable this merging — it is inherent to OLR's
architecture.

### How comparison scripts handle this

- **`compare.py`**: `normalize_lob_operations()` detects `EMPTY_CLOB()`/
  `EMPTY_BLOB()` literals in LogMiner's parsed SQL and merges consecutive
  events on the same XID + table. Unfilled EMPTY_CLOB/EMPTY_BLOB values are
  removed (LogMiner couldn't capture the data).
- **`compare-debezium.py`**: `merge_lob_events()` merges consecutive events
  on the same row (matched by shared key column values). Columns with
  `__debezium_unavailable_value` are skipped during comparison.

---

## 2. Event Ordering

**LogMiner** returns events ordered by redo SCN (the physical order operations
were written to the redo log). **OLR** orders events by commit SCN (the
logical order transactions committed).

This means that for interleaved transactions, the event order can differ even
though both outputs contain the same set of events.

### How comparison scripts handle this

Both `compare.py` and `compare-debezium.py` use content-based matching (greedy
best-match by op type, table name, and column values) rather than positional
comparison. This makes them order-independent.

---

## 3. Column Coverage on UPDATE

**LogMiner** reconstructs SQL statements from redo. Its `SQL_REDO` UPDATE
output includes only the columns that appear in the `SET` clause (changed
columns) and `WHERE` clause (key columns).

**OLR** with supplemental logging enabled emits all columns that have
supplemental log data — which typically means all columns when
`ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS` is set on the table. This means OLR
UPDATEs may include columns that didn't change.

### How comparison scripts handle this

Both scripts skip columns present in only one side's output — extra OLR
columns or missing LogMiner columns are not treated as mismatches.

---

## 4. Numeric Representation

**LogMiner** outputs numeric values in Oracle's display format, which may
include scientific notation for floats (e.g., `3.1400001E+000`).

**OLR** outputs numeric values in its own format:
- BINARY_FLOAT: up to 9 significant digits (`std::setprecision(9)`)
- BINARY_DOUBLE: up to 17 significant digits (`std::setprecision(17)`)
- NUMBER: full Oracle precision (up to 38 digits), built directly from
  Oracle's internal format without intermediate `double` conversion

### IEEE 754 special values

- **LogMiner**: outputs `'Nan'`, `'Inf'`, `'-Inf'` (non-standard casing)
- **OLR** (json-number-type=0): outputs `null`
- **OLR** (json-number-type=1): outputs `"NaN"`, `"Infinity"`, `"-Infinity"`
  as JSON strings

### How comparison scripts handle this

- `compare.py`: `values_match()` uses relative tolerance (1e-6) for float
  comparison. `logminer2json.py` normalizes `Nan`→`NaN`, `Inf`→`Infinity`,
  `-Inf`→`-Infinity`.
- `compare-debezium.py`: same numeric tolerance.

---

## 5. Date/Timestamp Representation

**LogMiner** outputs dates and timestamps in Oracle's session format, typically:
- DATE: `DD-MON-RR` (e.g., `15-JUN-25`)
- TIMESTAMP: `DD-MON-RR HH.MI.SS.FF AM` (e.g., `15-JUN-25 10.30.00.123456 AM`)

**OLR** outputs epoch-based values (seconds since 1970-01-01 UTC).

### How comparison scripts handle this

`compare.py`: `try_parse_oracle_datetime()` parses Oracle date/timestamp
strings to epoch seconds for comparison. Date-only values compare at day
granularity (LogMiner truncates time component).

---

## 6. Whitespace in String Values

**LogMiner** replaces CR/LF characters in string values with spaces in
`SQL_REDO` output.

**OLR** preserves the original characters (CR, LF, CRLF) as they appear in
the redo log.

### How comparison scripts handle this

`compare.py`: `values_match()` normalizes `\r\n`→space, `\n`→space,
`\r`→empty before comparison as a fallback.

---

## 7. Long SQL_REDO Continuation Rows

When a LogMiner `SQL_REDO` value exceeds ~4000 characters (e.g., wide rows
with many columns), LogMiner splits it across multiple result rows with the
same SCN/operation/owner/table/XID prefix. The continuation rows have SQL
fragments that don't start with an SQL keyword.

OLR has no such limitation — it emits the full row in a single event.

### How comparison scripts handle this

`logminer2json.py`: `merge_continuation_lines()` detects and reassembles
split LogMiner rows before parsing.

---

## Summary

| Difference | LogMiner | OLR | Comparison Handling |
|---|---|---|---|
| LOB splitting | INSERT(empty) + UPDATE(data) | Single INSERT(data) | Merge consecutive events |
| Event ordering | Redo SCN order | Commit SCN order | Content-based matching |
| UPDATE columns | Changed + key only | All supplemental columns | Skip extra columns |
| Float format | Scientific notation | Fixed precision | Numeric tolerance |
| IEEE 754 specials | Nan/Inf/-Inf | null or NaN/Infinity/-Infinity | Normalization |
| Date/timestamp | Oracle display format | Epoch seconds | Parse + convert |
| Whitespace | CR/LF → space | Preserved | Normalize before compare |
| Long SQL_REDO | Split across rows | Single event | Reassemble before parse |
