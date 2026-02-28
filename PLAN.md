# OpenLogReplicator RAC Support — Gap Analysis Report

## 1. Background

### Oracle RAC Redo Log Semantics
In Oracle RAC, each instance has its own **redo thread** (identified by `THREAD#`). Each thread maintains:
- Independent online redo log groups (e.g., instance 1 uses groups 1-3, instance 2 uses groups 4-6)
- Independent sequence numbers (thread 1 may be at seq 45 while thread 2 is at seq 38)
- Independent archived redo logs (each labeled with thread + sequence)

All instances share the same database and SCN space. SCNs are globally ordered across threads, but sequence numbers are **per-thread** and independent.

### Current OLR Limitation
OLR documentation states: *"Database must be in single instance mode (non RAC)"*.

This report identifies every code-level assumption that enforces this limitation.

---

## 2. Gap Summary

| # | Area | Gap | Severity | Status |
|---|------|-----|----------|--------|
| G1 | SQL Queries | No THREAD# filtering in V$ queries | High | **Done** (Phase 1) |
| G2 | Metadata/Checkpoint | Single sequence/offset — not per-thread | High | **Done** (Phase 2) |
| G3 | Redo Log Discovery | RedoLog struct has no thread field | High | **Done** (Phase 1) |
| G4 | Online Log Processing | Single-sequence linear scan loop | High | **Done** (Phase 2) |
| G5 | Archived Log Processing | Single-sequence linear scan + single archReader | High | **Done** (Phase 2) |
| G6 | Reader | No thread member; hardcoded `enabledRedoThreads = 1` | Medium | **Done** (Phase 1) |
| G7 | Parser | Hardcoded `thread = 1` in dump output | Low | Open |
| G8 | SCN Merge / Ordering | No cross-thread SCN merge layer | High | **Done** (Phase 3) |
| G9 | Checkpoint Serialization | JSON format stores single seq/offset | High | **Done** (Phase 2) |
| G10 | Transaction Buffer | XID map key has no thread qualifier | Low | Open |
| G11 | Config Schema | No thread/instance concept in JSON config | Medium | Open |
| G12 | Archive Filename Parsing | Thread token `%t` parsed but discarded | Medium | **Done** (Phase 1) |

---

## 3. Detailed Gap Analysis

### G1: SQL Queries Lack THREAD# Awareness

**Files:** `src/replicator/ReplicatorOnline.h`

Four SQL queries hit V$ views without THREAD# filtering:

1. **`SQL_GET_LOGFILE_LIST`** (line 158-171) — Queries `V$LOGFILE` to discover redo log groups. In RAC, this returns groups from ALL instances. Without filtering by thread, OLR cannot distinguish which groups belong to which instance.

2. **`SQL_GET_ARCHIVE_LOG_LIST`** (line 34-51) — Queries `V$ARCHIVED_LOG` for archived logs. Does not SELECT `THREAD#` and does not filter by it. In RAC, archived logs from all threads are mixed together.

3. **`SQL_GET_SEQUENCE_FROM_SCN`** (line 120-137) — Takes `MAX(SEQUENCE#)` across a UNION of `V$LOG` and `V$ARCHIVED_LOG`. In RAC, `MAX(SEQUENCE#)` across threads is meaningless — thread 1 seq 100 and thread 2 seq 50 are unrelated.

4. **`SQL_GET_PARAMETER`** (line 173-181) — Queries `V$PARAMETER`. Some parameters (like `log_archive_format`) are instance-level and may differ per RAC node.

**Fix direction:** Add `THREAD#` to SELECT and WHERE clauses. Run log discovery queries per-thread, or filter by the target thread.

---

### G2: Single-Valued Checkpoint Metadata

**File:** `src/metadata/Metadata.h` (lines 110-133)

All checkpoint state is stored as single scalar values:

```cpp
Seq sequence{Seq::none()};          // line 114 — ONE sequence for the whole system
FileOffset fileOffset;               // line 116 — ONE file offset
Seq checkpointSequence{Seq::none()}; // line 126
FileOffset checkpointFileOffset;     // line 127
Seq minSequence{Seq::none()};        // line 131
FileOffset minFileOffset;            // line 132
```

In RAC, each thread has its own independent sequence number stream. The checkpoint must track position per-thread: e.g., `{thread1: seq=100, offset=4096, thread2: seq=50, offset=8192}`.

**File:** `src/metadata/Metadata.cpp` — `setNextSequence()` does `++sequence` (single linear increment), which is only valid for a single thread.

**Fix direction:** Change checkpoint fields to per-thread maps, e.g., `std::map<uint16_t, Seq> sequenceByThread`.

---

### G3: RedoLog Struct Has No Thread Field

**File:** `src/metadata/RedoLog.h` (lines 28-46)

```cpp
class RedoLog final {
public:
    int group;
    std::string path;
};
```

The `RedoLog` struct only stores `group` and `path`. In RAC, each log group belongs to a specific thread. Without a `thread` field, OLR cannot associate log groups with their owning instance.

**Fix direction:** Add `uint16_t thread` member to `RedoLog`.

---

### G4: Online Log Processing — Single-Sequence Linear Scan

**File:** `src/replicator/Replicator.cpp` (lines 812-910)

`processOnlineRedoLogs()` searches `onlineRedoSet` for a log matching `metadata->sequence`:

```cpp
if (onlineRedo->reader->getSequence() == metadata->sequence && ...)
    parser = onlineRedo;
```

This assumes all online redo logs share a single sequence stream. In RAC, multiple threads produce logs simultaneously with independent sequences. The function needs to track and process logs from each thread independently.

After parsing, `metadata->setNextSequence()` increments a single global sequence counter (line 888), which doesn't account for multiple threads advancing independently.

**Fix direction:** Maintain per-thread processing state. Process logs from each thread's sequence independently, then merge by SCN.

---

### G5: Archived Log Processing — Single-Sequence + Single Reader

**File:** `src/replicator/Replicator.cpp` (lines 690-809)

`processArchivedRedoLogs()` uses a single priority queue (`archiveRedoQueue`) and processes logs linearly by sequence:

```cpp
if (parser->sequence < metadata->sequence)    // skip older
if (parser->sequence > metadata->sequence)    // wait for gap
// On completion:
++metadata->sequence;                          // line 792
```

In RAC, archived logs from different threads have independent sequences. Comparing `thread1_seq=5` against `thread2_seq=7` is meaningless.

There is also only a single `archReader` (line 751: `parser->reader = archReader`), meaning only one archived log can be read at a time. For RAC, reading multiple threads' archives concurrently would be needed.

**Fix direction:** Maintain separate archive queues and readers per thread. Process each thread's archive stream independently.

---

### G6: Reader Has No Thread Member

**File:** `src/reader/Reader.h` (lines 80-81)

```cpp
int group;
Seq sequence;
// No thread member
```

The Reader reads and validates redo log file headers. At line 880 of `Reader.cpp`, the thread number IS read from the redo header:

```cpp
const uint16_t thread = ctx->read16(headerBuffer + blockSize + 176);
```

But it's only used for `printHeaderInfo()` display output — never stored as a class member or returned to callers.

At line 1007:
```cpp
constexpr uint16_t enabledRedoThreads = 1; // TODO: find field position/size
```

This hardcoded value prevents proper RAC thread detection.

**Fix direction:** Add `uint16_t thread` to Reader. Store the thread value read from the redo header. Use it to validate that the right thread's logs are being read.

---

### G7: Parser Hardcodes Thread = 1

**File:** `src/parser/Parser.cpp` (line 126)

```cpp
constexpr uint16_t thread = 1; // TODO: verify field size/position
```

Used only in dump output (debug logging), so this is low severity. But it indicates the parser has no awareness of which thread it's processing.

**Fix direction:** Pass thread from Reader to Parser, or read it from the redo record header.

---

### G8: No Cross-Thread SCN Merge Layer

This is an **architectural gap** — no single file, but rather a missing component.

In single-instance mode, redo records are naturally SCN-ordered within a single log stream. In RAC, each thread produces its own SCN-ordered stream, but to present a globally consistent view, these streams must be **merged by SCN** before transactions are emitted.

Currently:
- `Replicator::processOnlineRedoLogs()` feeds one log at a time to the parser
- Parser processes records sequentially within that log
- Transactions are committed to the output when their commit record is seen

For RAC, a merge layer is needed that:
1. Reads from multiple threads concurrently
2. Merges redo records (or at minimum, commit events) in global SCN order
3. Ensures a transaction that spans threads (via distributed transactions) is handled correctly

**Fix direction:** Add a merge/coordinator component between per-thread readers and the transaction output layer.

---

### G9: Checkpoint JSON Format — Single Sequence/Offset

**File:** `src/metadata/SerializerJson.cpp` (lines 52-67)

The checkpoint JSON looks like:
```json
{
  "database": "...",
  "scn": 12345,
  "seq": 100,
  "offset": 4096,
  "min-tran": {"seq": 95, "offset": 2048, "xid": "..."}
}
```

Single `seq` and `offset` values. For RAC, these must become per-thread:
```json
{
  "threads": {
    "1": {"seq": 100, "offset": 4096},
    "2": {"seq": 50, "offset": 8192}
  },
  "min-tran": {
    "1": {"seq": 95, "offset": 2048, "xid": "..."},
    "2": {"seq": 48, "offset": 1024, "xid": "..."}
  }
}
```

**Fix direction:** Change serialization format to per-thread checkpoint state. Handle backward compatibility for existing single-thread checkpoints.

---

### G10: Transaction Buffer XID Map Key

**File:** `src/parser/TransactionBuffer.cpp` (line 57)

```cpp
const XidMap xidMap = (xid.getData() >> 32) | ((static_cast<uint64_t>(conId)) << 32);
```

The XID map key uses `USN + SLT + conId` but no thread component. In RAC, Oracle's XID format includes the instance number in the USN space, so in practice XIDs are unique across instances. This is **low severity** — XIDs should not collide. However, the conflict check at line 63-64 may need awareness that the same logical transaction could appear in logs from different threads (e.g., distributed transactions).

**Fix direction:** Verify that Oracle RAC XID uniqueness guarantees hold. If distributed transactions are supported, ensure cross-thread transaction assembly works correctly.

---

### G11: Config Schema Has No Thread/Instance Concept

**File:** `src/OpenLogReplicator.cpp` (lines 227-363)

The reader config accepts:
```json
{
  "reader": {
    "type": "online",
    "server": "...",
    "user": "...",
    "start-seq": 100
  }
}
```

`start-seq` is a single uint32 — not per-thread. There's no way to specify:
- Which RAC instances/threads to process
- Per-thread starting positions
- Connection to multiple RAC nodes (for reading local redo logs via ASM)

**Fix direction:** Add RAC-aware config options: thread list, per-thread start-seq, potentially multiple reader connections.

---

### G12: Archive Filename Parser Discards Thread Token

**File:** `src/replicator/Replicator.cpp` (lines 338-409)

`getSequenceFromFileName()` parses `log_archive_format` tokens including `%t` (thread) and `%T` (zero-filled thread). The thread number IS parsed from the filename, but only `%s`/`%S` (sequence) is stored in the return value. The thread value is discarded.

```cpp
if (logArchiveFormat[i + 1] == 's' || logArchiveFormat[i + 1] == 'S')
    sequence = Seq(number);   // Only sequence is captured
// %t and %T: number is parsed but not stored anywhere
```

**Fix direction:** Return both thread and sequence from this function (e.g., as a struct).

---

## 4. Implementation Priority & Progress

### Phase 1: Core Thread Awareness — DONE (commit `2c79c0f0`)
1. **G3** — Add thread to RedoLog struct ✓
2. **G6** — Add thread to Reader, store value from header ✓
3. **G1** — Add THREAD# to SQL queries ✓
4. **G12** — Return thread from archive filename parser ✓

### Phase 2: Per-Thread Processing — DONE (commit `f180920c`)
5. **G2** — Make checkpoint metadata per-thread ✓
6. **G4** — Per-thread online log processing ✓
7. **G5** — Per-thread archive log processing ✓
8. **G9** — Per-thread checkpoint serialization ✓

Tested on 2-node RAC 23.26.1.0: DML from both nodes captured, per-thread checkpoints verified.

### Phase 3: Global Ordering — DONE
9. **G8** — SCN-ordered archive interleaving ✓

Archives are now processed one-at-a-time from the thread with the lowest SCN range
(via `pickNextArchiveThread()`), instead of all-thread-1-then-all-thread-2. Online redo
log processing also prefers the thread with the lower firstScn. This provides approximately
global SCN ordering — correct at archive-log granularity, with per-thread ordering within
overlapping SCN ranges.

### Phase 4: Config & Polish — NOT STARTED
10. **G11** — RAC-aware config schema
11. **G7** — Thread-aware parser dump output
12. **G10** — Verify XID handling for distributed transactions

---

## 5. Key Observations

1. **Existing TODO markers**: The author already placed `// TODO` comments at the two hardcoded `thread = 1` locations (Reader.cpp:1007, Parser.cpp:126), indicating RAC support was considered during development.

2. **Thread is already in the redo header**: Reader.cpp:880 already reads the thread number from the correct header offset. The infrastructure for reading thread info exists — it just needs to be stored and propagated.

3. **Archive format already supports thread tokens**: The `%t`/`%T` tokens in `getSequenceFromFileName()` are already parsed. Only the return value needs expansion.

4. **SCN merge is the hardest part**: Gaps G1-G7 and G9-G12 are data-model and plumbing changes. G8 (cross-thread SCN merge) is the core architectural challenge, requiring careful design for correctness, especially around:
   - Transaction ordering guarantees
   - Checkpoint consistency (must be able to resume from any point)
   - Distributed transactions spanning multiple instances

5. **Single vs. multi-connection**: OLR currently connects to one Oracle instance. For RAC, it could either:
   - Connect to one instance and read all threads' redo via shared storage (ASM)
   - Connect to each instance separately to read local redo logs

   Both approaches are viable; the first is simpler but requires shared storage access.

---

## 6. Test Coverage Improvement Plan

### Current Coverage (10 fixtures, all passing)

| Category | Fixture | What's Tested |
|----------|---------|---------------|
| Basic DML | basic-crud | INSERT, UPDATE, DELETE on single table |
| Types | data-types | VARCHAR2, CHAR, NVARCHAR2, NUMBER, FLOAT, DOUBLE, DATE, TIMESTAMP, RAW |
| Nulls | null-handling | NULL insert, value→NULL, NULL→value |
| Transactions | rollback | Commit, rollback, savepoint partial rollback |
| Multi-table | multi-table | 3 tables in mixed transactions |
| Bulk | large-transaction | 200-row insert, bulk update, bulk delete |
| Strings | special-chars | Quotes, backslashes, tabs, newlines, CRLF |
| RAC | rac-interleaved | Same table, alternating DML from 2 nodes |
| RAC | rac-concurrent-tables | Different tables per node |
| RAC | rac-thread2-only | All DML on non-primary thread |

All fixtures are auto-discovered by the parameterized gtest suite (`tests/test_pipeline.cpp`).
New `.sql` scenarios added to `tests/fixtures/scenarios/` and generated via `generate.sh`
(or `generate-rac.sh` for RAC) are picked up automatically by ctest.

### Tier 1 — Core features with zero coverage

These are supported in OLR source code but have no test fixtures.

| # | Fixture | What to Test | Relevant Code |
|---|---------|-------------|---------------|
| T1 | ~~lob-operations~~ | **DEFERRED** — LogMiner splits LOB writes, OLR merges them | See note below |
| T2 | partitioned-table | DML across range/list partitions | **Done** |
| T3 | ~~ddl-schema-change~~ | **DEFERRED** — LogMiner pipeline can't validate DDL | See note below |
| T4 | number-precision | MAX precision (38 digits), BINARY_FLOAT/DOUBLE, pi | **Done** |
| T5 | timestamp-variants | DATE, TIMESTAMP(0/3/6/9), NULLs, edge cases | **Done** |

> **T1 deferred:** LogMiner splits LOB writes into INSERT(EMPTY_CLOB/EMPTY_BLOB) + UPDATE(actual value),
> while OLR merges them into a single INSERT with the final value. `compare.py` sees 14 LogMiner
> records vs 8 OLR records and reports a mismatch. Requires LOB-aware merging in `compare.py`
> or a different validation approach.
>
> **T3 deferred:** DDL (ALTER TABLE ADD/DROP COLUMN) changes the table schema mid-stream.
> Our `logminer2json.py` only parses INSERT/UPDATE/DELETE SQL_REDO, not DDL statements.
> `compare.py` matches columns by name — column additions/drops mid-test would cause
> mismatches between LogMiner and OLR output. Testing DDL requires a different validation
> approach (e.g., manual golden files or a DDL-aware comparison tool).

### Tier 2 — Important reliability gaps

| # | Fixture | What to Test | Relevant Code |
|---|---------|-------------|---------------|
| T6 | long-wide-rows | VARCHAR2(4000) values, chained rows spanning blocks | opcode 0x0B05 (chained row) |
| T7 | boolean-type | Oracle 23ai BOOLEAN columns | COLTYPE 252 |
| T8 | concurrent-updates | Same row updated across multiple rapid commits | Transaction ordering, before/after consistency |
| T9 | interleaved-transactions | Multiple open transactions with interleaved DML | Transaction correlation across redo records |
| T10 | schemaless-mode | Batch mode with `flags:2`, no schema checkpoint | Adaptive/schemaless path in builder |

### Tier 3 — Edge cases and robustness

| # | Fixture | What to Test |
|---|---------|-------------|
| T11 | empty-transactions | BEGIN + COMMIT with no DML |
| T12 | very-large-transaction | 10K+ rows in single commit (memory pressure) |
| T13 | rac-same-row | Both RAC nodes updating the same row |
| T14 | multibyte-charset | JA16SJIS / ZHS16GBK / AL32UTF8 4-byte characters |
| T15 | raw-binary-data | RAW columns with binary nulls, high bytes |

### Implementation Notes

- **Tier 1 status:** T2, T4, T5 done. T1 (LOB) and T3 (DDL) deferred — both require validation approaches that don't depend on LogMiner.
- All scenarios use the existing `generate.sh` pipeline — just new `.sql` files.
- T2 (partitions) may need setup grants beyond current `olr_test` user.
- T7 (BOOLEAN) requires Oracle 23ai which our RAC VM already runs.
- T13 (rac-same-row) uses `generate-rac.sh` with a `.rac.sql` file.
- T14 (multibyte) may need a separate PDB or NLS parameter changes.
