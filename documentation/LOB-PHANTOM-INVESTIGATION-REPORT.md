# LOB Phantom Event Investigation Report

## Issue

OpenLogReplicator (OLR) emits CDC events for rows that do not exist in the
Oracle database. These "phantom" events appear exclusively on tables with LOB
columns (CLOB/BLOB) when running on Oracle RAC. A CDC consumer replicating
from OLR would have rows in its target table that do not exist in the source
database — data corruption.

**Tracked as:** rophy/OpenLogReplicator#15

## Test Environment

- **Oracle**: AI Database 26ai Enterprise Edition Release 23.26.1.0.0, 2-node RAC
- **OLR**: v1.9.0 + RAC support fork (rophy/OpenLogReplicator master branch)
- **Debezium**: 3.5.0.Beta1 (used as LogMiner baseline via `logminer_unbuffered`)
- **Workload**: randomized PL/SQL fuzz generator (7 table types including LOB,
  with batched transactions and savepoint rollbacks)
- **RAC VM**: 2-node Oracle RAC on libvirt/KVM, documented in `oracle-rac/DEPLOY.md`

## Test Methodology

### 3-Way Comparison

We compare three sources of truth:

1. **Database snapshot** — `SELECT * FROM table` after workload completes.
   This is the ground truth.
2. **LogMiner replay** — Debezium `logminer_unbuffered` adapter, which uses
   Oracle's `COMMITTED_DATA_ONLY` mode. Proven 100% accurate against DB
   (0 mismatches across 158K rows).
3. **OLR replay** — OLR streaming via Debezium OLR adapter to Kafka.

Both CDC adapters publish to separate Kafka topics. A consumer writes events
to SQLite. After workload completes, a sentinel INSERT is committed. The
validator waits for both adapters to deliver the sentinel, then replays all
events into final row state and compares against the database.

### Sentinel-Based Drain

After the fuzz workload ends, a sentinel row (`id=-1, event_id='SENTINEL'`)
is inserted into `FUZZ_SCALAR`. Both CDC adapters will process this INSERT.
The validator polls the SQLite DB until both sides deliver the sentinel,
guaranteeing all prior DML has been processed. This eliminates false positives
from timing lag.

**Why not use `current_scn`?** Oracle's SCN advances every ~3 seconds from
internal activity, even without DML. CDC adapters only emit events for actual
DML, so they can never reach a `current_scn` watermark. The sentinel approach
guarantees a DML event at a known SCN that both adapters will process.

### Tools

- `fuzz-test.sh run N` — runs N-minute fuzz workload on both RAC nodes
- `fuzz-test.sh validate` — LM-vs-OLR event-level comparison
- `fuzz-test.sh db-check` — 3-way comparison against database ground truth

## Observations

### 1. Non-LOB Tables: 100% Accurate

Across all test runs (5-minute, 10-minute, 60-minute), OLR achieves **zero
mismatches** on non-LOB tables:

| Table | Type | Events | Missing | Extra | Diffs |
|-------|------|--------|---------|-------|-------|
| FUZZ_SCALAR | VARCHAR2, NUMBER, DATE | ~11,000 | 0 | 0 | 0 |
| FUZZ_WIDE | 30+ columns | ~1,100 | 0 | 0 | 0 |
| FUZZ_PART | LIST-partitioned | ~1,800 | 0 | 0 | 0 |
| FUZZ_INTERVAL | INTERVAL types | ~600 | 0 | 0 | 0 |
| FUZZ_MAXSTR | MAX VARCHAR2 | ~600 | 0 | 0 | 0 |

Verified with `SKIP_LOB=1` flag: 35,000+ events, 100% match.

### 2. LOB Tables: Phantom Events

Typical 5-minute run (db-check against database):

```
DB vs OLR:
  Matched:  15,908
  Missing:  0
  Extra:    46 (all FUZZ_LOB)
  Diffs:    6 (all FUZZ_LOB LABEL)
```

OLR captures **every committed row** (0 missing) but emits 46 extra rows
that do not exist in the database, plus 6 rows with incorrect LABEL values.

### 3. LogMiner with COMMITTED_DATA_ONLY: Perfect Baseline

```
DB vs LM (logminer_unbuffered):
  Matched:  31,985
  Missing:  0
  Extra:    0
  Diffs:    0
```

Oracle's `COMMITTED_DATA_ONLY` mode correctly filters all phantom events.
This confirms the phantom events are Oracle-internal operations, not user DML.

### 4. What the Phantom Events Are

Querying `V$LOGMNR_CONTENTS` for a transaction containing phantom events
(XID 28.17.2862):

**Without COMMITTED_DATA_ONLY:**

| SCN | RB | OP | ROW_ID | DATA_OBJD# | Description |
|-----|----|----|--------|------------|-------------|
| 42415786 | NO | UPDATE | placeholder | 0 | User: `SET LABEL='upd_n1_292'` |
| 42415791 | NO | INSERT | placeholder | 0 | User: new LOB row |
| 42415791 | NO | INSERT | placeholder | 0 | User: new LOB row |
| 42415791 | NO | INSERT | placeholder | 0 | User: new LOB row |
| 42415791 | NO | UPDATE | real ROWID | 83260 | Internal: LOB segment mgmt |
| 42415833 | YES | DELETE | real ROWID | 83260 | Internal: phantom undo |
| 42415833 | YES | DELETE | real ROWID | 83260 | Internal: phantom undo |
| 42415833 | YES | DELETE | real ROWID | 83260 | Internal: phantom undo |

**With COMMITTED_DATA_ONLY:**
The 3 phantom INSERTs, the internal UPDATE, and the 3 phantom DELETEs are all
absent. Only the user UPDATEs remain.

**Key observations:**
- User DML: `DATA_OBJD# = 0`, `ROW_ID = AAAAAAAAAAAAAAAAAA` (placeholder)
- Internal LOB ops: `DATA_OBJD# = 83260` (table's data_object_id), real ROWIDs
- Phantom undo: `ROLLBACK = YES`, `DATA_OBJD# = 83260`, real ROWIDs
- `COMMITTED_DATA_ONLY` removes both the internal ops AND the phantom INSERTs

### 5. Oracle's LOB Storage Architecture

Per Oracle documentation, LOBs use a versioning model:

> "LOBs will never generate rollback information (undo) for LOB data pages
> because old LOB data is stored in versions."

Oracle stores out-of-row LOB data in separate LOB segments with their own
index. Internal LOB segment management generates DML on the base table
(INSERTs, UPDATEs, DELETEs) that appear in the redo log but are not
user-visible operations. `COMMITTED_DATA_ONLY` understands this internal
structure and filters them.

## Signals Investigated for Discrimination

We investigated multiple raw redo fields to find a signal that could
distinguish Oracle internal LOB operations from user DML:

### dataObj (OLR's data_object_id from redo)

**Result: Not usable.**

LogMiner shows `DATA_OBJD# = 0` for user DML and `DATA_OBJD# = 83260` for
internal LOB ops. However, OLR's `dataObj` field (parsed from raw redo) is
always `83260` for both — the propagation code at `Parser.cpp:908` unifies
the undo and redo records, overwriting the zero value.

### bdba + slot (block address + slot number)

**Result: Not usable.**

When used to match undo against the stack top (only apply rollback when
bdba+slot match), it caused 17,000+ false rollbacks. Oracle reuses
block+slot within transactions, so matching bdba+slot doesn't reliably
identify the target operation.

### suppLogBdba (supplemental logging ROWID)

**Result: Not usable.**

All phantom LOB undos have `suppLogBdba = 0` (no supplemental logging data).
However, many legitimate undos also have `suppLogBdba = 0` (supplemental log
data may not be set at undo time). Using this as a discriminator caused
19,000+ extra events.

### Opcode pairing + !lobStripped (current heuristic)

**Result: Best available, partial coverage.**

The current check:
```cpp
if (!lobStripped && deferCommittedTransactions &&
    ((stackOp == 0x0B02 && undoOp == 0x0B03) ||   // INSERT → DELETE
     (stackOp == 0x0B05 && undoOp == 0x0B05)))     // UPDATE → UPDATE
```

This catches phantom undos when:
- No LOB index records were stripped from the stack (`!lobStripped`)
- The opcode pair matches INSERT→DELETE or UPDATE→UPDATE
- The table has LOB columns

It does NOT catch phantom undos with mismatched opcodes (e.g., UPDATE on
stack but DELETE undo arriving — produces warning 70003 and the undo is
discarded, leaving the phantom INSERT in the buffer).

Coverage: catches ~60% of phantom undos. ~46 phantom events remain per
5-minute run (~0.3% of LOB events).

### DATA_OBJD# = 0 (LogMiner presentation layer)

**Result: Works in LogMiner, not available in raw redo.**

This is the signal `COMMITTED_DATA_ONLY` uses internally. LogMiner presents
user DML with `DATA_OBJD# = 0` (row not yet physically allocated) and internal
LOB ops with `DATA_OBJD# = table_data_object_id`. This information exists in
LogMiner's processing layer but is not present in the raw redo records that
OLR reads.

## Conclusion

**OLR cannot guarantee zero phantom LOB events on Oracle RAC.**

The phantom operations are Oracle's internal LOB segment management. They
appear as committed DML in the redo log and are indistinguishable from user
DML at the raw redo level. Only Oracle's `COMMITTED_DATA_ONLY` mode (used by
LogMiner internally) can correctly filter them, using Oracle-internal state
not available in the redo stream.

### Recommendation

| Use case | Recommendation |
|----------|---------------|
| Non-LOB tables on RAC | OLR — 100% accurate |
| LOB tables requiring zero phantom events | Use Debezium `logminer_unbuffered` adapter |
| LOB tables tolerant of ~0.3% extra events | OLR with `KNOWN_LOB_TABLES` in validator |

### What OLR Does Correctly

- **Zero missing rows** — every committed row is captured
- **100% non-LOB accuracy** — across all table types and data types
- **LOB content delivery** — OLR reads LOB data directly from redo, delivering
  actual CLOB/BLOB values that LogMiner cannot provide
- **Phantom INSERT detection** — the opcode heuristic catches ~60% of phantom
  undos, reducing the phantom rate
- **FLG_ROLLBACK_OP0504** — correctly suppresses transaction-level rollbacks
  on LOB tables

### Known Limitations

- **~0.3% phantom LOB events on RAC** — INSERTs for rows that don't exist in
  the database, from Oracle's internal LOB segment management
- **~0.04% LOB label diffs on RAC** — phantom UPDATEs that change scalar
  columns (LABEL) within the same transaction as LOB operations
- **LOB before-images** — not available in redo (documented Oracle limitation,
  affects all CDC tools)
