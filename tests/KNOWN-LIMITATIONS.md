# Known Limitations and Bugs

Each entry includes evidence from source code, Oracle behavior, or test
results. Claims without evidence should not be added.

Entries are split into two categories:
- **External limitations** (L1-L7): Oracle LogMiner or Debezium behavior that
  cannot be fixed in OLR. These require workarounds in test comparison scripts.
- **OLR bugs** (L8-L12): Issues in OLR that should be fixed. Each has a
  corresponding GitHub issue.

---

## L1. LogMiner LOB SQL_UNDO Always Returns NULL

Oracle LogMiner does not provide the previous LOB value in `SQL_UNDO` for
UPDATE operations on LOB columns. The undo always contains `SET "col" = NULL`
regardless of the actual previous value.

**Evidence — raw LogMiner output:**

```sql
-- UPDATE TEST_LOB_RAW SET col_clob = 'Updated CLOB value' WHERE id = 1;
-- (previous value was 'Original CLOB value')

-- SQL_REDO:
update "OLR_TEST"."TEST_LOB_RAW" set "COL_CLOB" = 'Updated CLOB value' where ...;
-- SQL_UNDO:
update "OLR_TEST"."TEST_LOB_RAW" set "COL_CLOB" = NULL where ...;
```

Reproduced on Oracle XE 21c (2026-03-16) by running LogMiner directly via
`DBMS_LOGMNR` against archived redo containing a CLOB UPDATE.

**Impact:** Debezium's `before` image for LOB columns on UPDATE/DELETE always
contains `__debezium_unavailable_value` because the old value is simply not
available from Oracle's redo data. This is true for all three Debezium Oracle
adapters (LogMiner, Xstream, OLR).

**Evidence — Debezium source code:**

- `OracleBlobDataTypesIT.java` (19 occurrences):
  `// blob fields will never have a "before" state; emitted with unavailable value placeholder`
- `OracleClobDataTypeIT.java:267`:
  `// clob fields will never have a "before" state; emitted with unavailable value placeholder`
- `LcrEventHandler.java:227`:
  `// again Xstream doesn't supply before state for LOB values; explicitly use unavailable value`

**Test handling:** `compare-debezium.py` skips columns where either side has
`__debezium_unavailable_value` (line 186-188).

---

## L2. LogMiner SQL_REDO Cannot Represent Large LOBs

For out-of-row LOBs (typically >4000 bytes), LogMiner's `SQL_REDO` cannot
represent the full LOB content. The INSERT appears as `EMPTY_CLOB()` /
`EMPTY_BLOB()` with no follow-up UPDATE containing the actual data.

**Evidence — raw LogMiner output for large CLOB insert:**

```
-- SQL_REDO for INSERT with 8KB CLOB:
insert into "OLR_TEST"."TEST_NCHAR"(...) values (..., EMPTY_CLOB(), ...);
-- No follow-up UPDATE with actual CLOB data
```

Reproduced in fixture generation for `nchar-nclob` scenario (2026-03-16).
LogMiner record 15 shows `EMPTY_CLOB()` with no continuation.

**Note:** This is a limitation of LogMiner's SQL reconstruction (`SQL_REDO`),
not of LogMiner's internal processing. When accessed via Debezium with
`lob.enabled=true`, Debezium uses LogMiner's `LOB_WRITE` events (not
`SQL_REDO`) to capture large LOB data correctly.

**Test handling:** `compare.py` removes unfilled `EMPTY_CLOB()`/`EMPTY_BLOB()`
values after LOB normalization, and skips comparison when LogMiner has empty
string and OLR has actual content (line 239-240).

---

## L3. LogMiner Does Not Support UROWID

LogMiner outputs the literal string `Unsupported Type` for UROWID column
values in `SQL_REDO`.

**Evidence:** Observed in fixture generation (2026-03-01). OLR decodes UROWID
correctly from redo but the value cannot be validated against LogMiner.

**Tracked:** [rophy/olr#11](https://github.com/rophy/olr/issues/11)

**Test handling:** UROWID test scenario was removed — cannot validate against
LogMiner.

---

## L4. LogMiner Does Not Support BOOLEAN in SQL_REDO (Oracle 23ai)

Oracle 23ai introduced the BOOLEAN data type. LogMiner does not include
BOOLEAN columns in `SQL_REDO` output.

**Evidence:** Observed in fixture generation against Oracle 23ai Free (2026-03-05).
BOOLEAN columns are absent from LogMiner's reconstructed SQL.

**Test handling:** No BOOLEAN test scenario — cannot validate against LogMiner.

---

## L5. LogMiner NCHAR/NVARCHAR2 Uses UNISTR() Encoding

LogMiner outputs national character set values using Oracle's `UNISTR()`
function with `\XXXX` Unicode escape sequences, rather than literal characters.

**Evidence — raw LogMiner output:**

```
-- For NVARCHAR2 value '변경된 텍스트':
-- SQL_REDO:
... "COL_NVARCHAR2" = UNISTR('\BCC0\ACBD\B41C \D14D\C2A4\D2B8') ...
```

Reproduced in fixture generation for `nchar-nclob` scenario on XE 21c
(2026-03-16).

**Test handling:** `logminer2json.py` decodes `UNISTR()` via `decode_unistr()`
function that converts `\XXXX` escape sequences to Unicode characters.

---

## L6. Debezium LOB Support Defaults to Disabled

Debezium Oracle connector's `lob.enabled` property defaults to `false`. When
disabled, all LOB columns are emitted as `__debezium_unavailable_value`
regardless of size, and LOB content is never compared.

**Evidence — Debezium source:**

`OracleConnectorConfig.java:330-338` — `LOB_ENABLED` field with
`default: false`.

**Evidence — test observation (2026-03-16):** With `lob.enabled=false`
(default), the Debezium twin-test `lob-operations` and `large-lobs` scenarios
passed but LOB columns were skipped by `compare-debezium.py`'s
`is_unavailable()` check — LOB content was never actually compared.

**Fix applied:** Added `debezium.source.lob.enabled=true` to both
`application-logminer.properties` configs (single-node and RAC). LOB content
is now compared in Debezium twin-tests.

---

## L7. Debezium OLR Adapter Does Not Support Mid-Stream Schema Evolution

The Debezium OLR adapter cannot handle ALTER TABLE during streaming. It uses
the schema from the initial snapshot and does not refresh it when DDL events
arrive.

**Evidence — Debezium source:**

`OpenLogReplicatorStreamingChangeEventSource.java:254-268`:
```java
Table table = schema.tableFor(tableId);
if (table == null) {
    Optional<Table> result = potentiallyEmitSchemaChangeForUnknownTable(...);
    if (result.isEmpty()) {
        return;  // Event silently skipped
    }
}
```

The LogMiner adapter handles this via JDBC dictionary refresh
(`dispatchSchemaChangeEventAndGetTableForNewConfiguredTable()`), but the OLR
adapter lacks equivalent logic.

**Tracked:** [rophy/olr#13](https://github.com/rophy/olr/issues/13)

**Test handling:** DDL scenarios (`@DDL` marker) are skipped in Debezium
twin-test. They are validated in redo-log regression tests via direct LogMiner
comparison.

---

## L8. OLR Does Not Decode ROWID Column Values

OLR omits ROWID-type columns from output entirely. When a table has a column
of type ROWID (not the implicit pseudocolumn, but an explicit column storing
row addresses), OLR does not include it in before/after images.

**Evidence — Oracle internal type code (2026-03-16):**

```sql
-- SYS.COL$ for TEST_ROWID_REF.SRC_RID:
NAME       TYPE#
---------- ----------
SRC_RID    69
```

Oracle's internal type code for ROWID columns is **69**. OLR's `SysCol::COLTYPE`
enum (`src/common/table/SysCol.h`) does not include type 69 — it only has
`UROWID = 208`. These are different types: ROWID (69) is the traditional
fixed-format row address, UROWID (208) is the universal format for heap and
IOT row addresses.

**Evidence — test output (2026-03-16):**

`rowid-column` scenario: OLR's output for `TEST_ROWID_REF` contains only
`ID` and `LABEL` columns — `SRC_RID` (ROWID type 69) is completely absent.
LogMiner's output includes `SRC_RID` with actual ROWID values like
`AAAT+SAAAAAADxGAAA`.

**Test handling:** `rowid-column` scenario passes fixture generation (LogMiner
comparison) because `compare.py` skips columns missing from OLR output.
Debezium twin-test fails because OLR sends `null` while LogMiner sends the
actual ROWID value.

---

## L9. OLR Does Not Support Index-Organized Tables (IOT)

OLR does not discover or process Index-Organized Tables (`ORGANIZATION INDEX`).
IOT tables are not listed in OLR's metadata scan and no DML events are emitted.

**Evidence — test output (2026-03-16):**

`iot-table` scenario: OLR's metadata scan lists all heap tables in the schema
but `TEST_IOT` (created with `ORGANIZATION INDEX`) is absent. OLR produces
no output for the scenario.

**Test handling:** No test scenario — OLR needs code changes to support IOTs.

---

## L10. ~~OLR Crash on RAC LOB + Log Switch~~ (FIXED)

**Root cause:** `Ctx::getMemoryChunk()` returned `nullptr` during
`hardShutdown` (OOM condition), but 7 of 9 callers never checked for null.
Under tight memory + heavy LOB redo, the parser consumed all available chunks,
the reader's allocation failed silently, and the subsequent dereference
crashed.

**Fix:** Changed `getMemoryChunk()` to throw `RuntimeException(10018)` instead
of returning `nullptr` on hard shutdown. This is consistent with the existing
throw at line 489-490 (post-allocation shutdown check). Removed the one
now-unreachable null check in `MemoryManager::unswap()`.

**Validated:** Reproduced 10/10 on RAC VM with 32-64MB memory + LOB DML from
both nodes. After fix, OLR shuts down gracefully with error 10018 instead of
crashing.

**Tracked:** [rophy/olr#14](https://github.com/rophy/olr/issues/14)

---

## L11. OLR Does Not Support Invisible Columns

OLR's `SysCol.h` PROPERTY enum does not include a flag for invisible columns
(`ALTER TABLE ... SET INVISIBLE`). Invisible columns would be processed as
regular visible columns.

**Evidence — source code:**

`src/common/table/SysCol.h` lines 32-67: The PROPERTY enum includes HIDDEN,
UNUSED, GUARD, NESTED, VIRTUAL, and IDENTITY flags but no INVISIBLE flag.
Grep for "invisible" or "INVISIBLE" in the OLR codebase returns zero results.

**Test handling:** No test scenario — OLR needs code changes to support this.

---

## L12. OLR US7ASCII Charset Corruption

OLR misinterprets byte widths when the database character set is US7ASCII,
causing CLOB values to show as mojibake (e.g., `Short CLOB text` → CJK
characters).

**Evidence:** Reproduced on `xe-21-official` environment (pre-built XE image
with US7ASCII despite `ORACLE_CHARACTERSET=AL32UTF8` env var — env var only
applies at DB creation, not pre-built).

**Tracked:** [rophy/olr#2](https://github.com/rophy/olr/issues/2)

**Test handling:** `multibyte-passthrough` scenario uses `@TAG us7ascii`
(opt-in only).

---

## L13. LogMiner LOB After-Image Unavailable for Unchanged Columns

Oracle LogMiner only includes LOB (CLOB/BLOB) column values in change events
when the column was **explicitly set or changed** by the SQL statement.
Unchanged LOB columns are not included in the redo data and appear as
`__debezium_unavailable_value` in Debezium output.

This is documented behavior, not a bug. OLR reads LOB data directly from redo
log records and can deliver actual LOB content even when LogMiner cannot.

**Evidence — Debezium documentation:**

> Oracle only supplies column values for CLOB, NCLOB, and BLOB data types if
> they're explicitly set or changed in a SQL statement. As a result, change
> events never contain the value of an unchanged CLOB, NCLOB, or BLOB column.
> Instead, they contain placeholders as defined by the connector property,
> `unavailable.value.placeholder`.

Source: [Debezium Connector for Oracle — LOB support](https://debezium.io/documentation/reference/stable/connectors/oracle.html),
[DBZ-4276](https://github.com/debezium/debezium/pull/2929)

**Evidence — fuzz test (2026-03-29):** 776 value diffs on FUZZ_LOB table where
LogMiner has `__debezium_unavailable_value` and OLR has actual BLOB/CLOB data.
Zero reverse cases (OLR unavailable, LogMiner has value).

**Test handling:** `validator.py` skips comparison when either side has
`__debezium_unavailable_value` (both before and after images).

---

## Summary

### External Limitations (Oracle / Debezium — cannot be fixed in OLR)

| ID | Description | Source | Test Handling |
|----|------------|--------|---------------|
| L1 | LOB SQL_UNDO always NULL | Oracle LogMiner | Skip LOB before-images in comparison |
| L2 | Large LOB not in SQL_REDO | Oracle LogMiner SQL reconstruction | Use `lob.enabled=true` in Debezium; skip in raw comparison |
| L3 | UROWID unsupported in SQL_REDO | Oracle LogMiner | No test scenario |
| L4 | BOOLEAN unsupported in SQL_REDO | Oracle LogMiner (pre-23ai) | No test scenario |
| L5 | NCHAR uses UNISTR() encoding | Oracle LogMiner | Decode in logminer2json.py |
| L6 | LOB disabled by default | Debezium config | Set `lob.enabled=true` |
| L7 | No mid-stream DDL | Debezium OLR adapter | Skip DDL in twin-test ([#13](https://github.com/rophy/olr/issues/13)) |
| L13 | LOB after-image unavailable for unchanged cols | Oracle LogMiner / [Debezium docs](https://debezium.io/documentation/reference/stable/connectors/oracle.html) | Skip unavailable in validator |

### OLR Bugs (should be fixed)

| ID | Description | Issue | Test Scenario |
|----|------------|-------|---------------|
| L8 | ROWID column (type# 69) not decoded | [#15](https://github.com/rophy/olr/issues/15) | `rowid-column` |
| L9 | IOT not discovered in metadata | [#16](https://github.com/rophy/olr/issues/16) | `iot-table` |
| ~~L10~~ | ~~RAC LOB + log switch null pointer crash~~ (FIXED) | [#14](https://github.com/rophy/olr/issues/14) | — |
| L11 | Invisible columns not tracked | — | — |
| L12 | US7ASCII charset corruption | [#2](https://github.com/rophy/olr/issues/2) | `multibyte-passthrough` (@TAG) |
