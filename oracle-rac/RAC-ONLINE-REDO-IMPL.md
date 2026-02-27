# Implementation Guide: RAC Online Redo Multi-Thread Parsing with SCN Merge

## 1. Problem Statement

OLR **cannot properly parse online redo logs from Oracle RAC** (multiple instances).

### Root Cause

`processOnlineRedoLogs()` (`src/replicator/Replicator.cpp:920`) selects ONE parser (lowest `firstScn`) and calls `parser->parse()`. Inside `parse()` (`src/parser/Parser.cpp:1548`), when no new redo blocks are available, `reader->checkFinished()` (`src/reader/Reader.cpp:1176`) calls `condParserSleeping.wait(lck)`, blocking the entire Replicator thread **indefinitely** until Oracle writes more data to that specific redo log.

With RAC (2+ redo threads), OLR gets stuck reading Thread 1's online redo and never reads Thread 2, or vice versa. The only way Thread 2 data gets processed is if Thread 1 does a log switch (parser returns `REDO_FINISHED`), at which point the loop picks the next parser.

### What Works

**Archive logs** work correctly for RAC — `pickNextArchiveThread()` (`src/replicator/Replicator.cpp:724`) selects the thread with the lowest `firstScn`, and archives have known SCN boundaries.

### Goal

Enable simultaneous parsing of all redo threads' online logs, with correct SCN-ordered transaction emission.

---

## 2. Architecture Overview

### Current Data Flow (Single Instance)

```
Reader Thread (OS thread, per redo file)
    │  reads blocks from disk into ring buffer
    │  signals condParserSleeping when new blocks available
    ▼
Parser::parse() [called from Replicator thread, BLOCKS on checkFinished()]
    │  parses LWN records, builds transactions in TransactionBuffer
    │  on COMMIT: immediately calls transaction->flush()
    ▼
Transaction::flush() → Builder
    │  serializes transaction into BuilderQueue (linked list of memory chunks)
    ▼
Writer Thread (OS thread)
    │  reads from BuilderQueue, sends to Kafka/file/etc.
    ▼
Output
```

### Proposed Data Flow (RAC Multi-Thread)

```
Reader T1 (OS thread)     Reader T2 (OS thread)     ... Reader TN
    │                          │                          │
    ▼                          ▼                          ▼
Parser T1::parse()        Parser T2::parse()        Parser TN::parse()
  [YIELDS after LWN]       [YIELDS after LWN]       [YIELDS after LWN]
  [returns YIELD code]      [returns YIELD code]     [returns YIELD code]
    │                          │                          │
    └──────────────── Replicator thread (round-robin) ────┘
                              │
                    Pending Transaction Queue
                    (sorted by commitScn)
                              │
                    SCN Watermark = min(lastLwnScn across all threads)
                              │
                    Emit transactions with commitScn ≤ watermark
                              │
                    Transaction::flush() → Builder → Writer → Output
```

### Key Design Decision: Single-Threaded with Cooperative Yielding

**Why NOT OS threads per redo thread:**
- `ctx->parserThread` is a global pointer used 60+ times across 7+ files for memory allocation, context-setting, and thread-identity checks
- TransactionBuffer, Builder, and many metadata structures are not thread-safe
- Making them thread-safe would be a massive rewrite with high risk

**Instead:** Parser yields (returns early) when no more data is available, and the Replicator round-robins between parsers. Single-instance behavior is completely unchanged (`yieldOnWait` defaults to `false`).

---

## 3. Detailed Implementation

### 3.1 Step 1: Add YIELD Return Code to Reader

**Files:** `src/reader/Reader.h`, `src/reader/Reader.cpp`

#### Reader.h — Add YIELD to REDO_CODE enum (line 36-51)

```cpp
enum class REDO_CODE : unsigned char {
    OK,
    OVERWRITTEN,
    FINISHED,
    STOPPED,
    SHUTDOWN,
    EMPTY,
    YIELD,           // NEW: parser processed available data, more may come
    ERROR_READ,
    ERROR_WRITE,
    ERROR_SEQUENCE,
    ERROR_CRC,
    ERROR_BLOCK,
    ERROR_BAD_DATA,
    ERROR,
    CNT
};
```

#### Reader.h — Declare new method (near line 163, public section)

```cpp
[[nodiscard]] bool checkFinishedNonBlocking(Thread* t, FileOffset confirmedBufferStart);
```

#### Reader.cpp — Add "YIELD" to REDO_MSG array

Find the `REDO_MSG` initialization and add `"YIELD"` at position matching the enum (after "EMPTY", before "ERROR_READ").

#### Reader.cpp — Implement checkFinishedNonBlocking()

This is a non-blocking variant of `checkFinished()` (line 1160-1181). Instead of calling `condParserSleeping.wait(lck)`, it sets `ret = REDO_CODE::YIELD` and returns `true`.

```cpp
bool Reader::checkFinishedNonBlocking(Thread* t, FileOffset confirmedBufferStart) {
    t->contextSet(CONTEXT::MUTEX, REASON::READER_CHECK_FINISHED);
    {
        std::unique_lock lck(mtx);
        if (bufferStart < confirmedBufferStart.getData())
            bufferStart = confirmedBufferStart.getData();

        // All work done
        if (confirmedBufferStart.getData() == bufferEnd) {
            if (ret == REDO_CODE::STOPPED || ret == REDO_CODE::OVERWRITTEN ||
                ret == REDO_CODE::FINISHED || status == STATUS::SLEEPING) {
                // Truly finished (same as blocking version)
                t->contextSet(CONTEXT::CPU);
                return true;
            }
            // Instead of blocking, signal YIELD
            ret = REDO_CODE::YIELD;
            t->contextSet(CONTEXT::CPU);
            return true;
        }
    }
    t->contextSet(CONTEXT::CPU);
    return false;  // more data available in buffer, keep parsing
}
```

**Existing `checkFinished()` is NOT modified** — it remains for single-instance use.

---

### 3.2 Step 2: Add Yield Mode to Parser

**Files:** `src/parser/Parser.h`, `src/parser/Parser.cpp`

#### Parser.h — Add yield flag (near line 108, public section)

```cpp
bool yieldOnWait{false};  // When true, return YIELD instead of blocking in checkFinished
```

#### Parser.cpp — Modify parse() at the checkFinished call (line 1547-1555)

Current code:
```cpp
} else {
    if (reader->checkFinished(ctx->parserThread, confirmedBufferStart)) {
        if (reader->getRet() == Reader::REDO_CODE::FINISHED && nextScn == Scn::none() && reader->getNextScn() != Scn::none())
            nextScn = reader->getNextScn();
        if (reader->getRet() == Reader::REDO_CODE::STOPPED || reader->getRet() == Reader::REDO_CODE::OVERWRITTEN)
            metadata->fileOffset = FileOffset(lwnConfirmedBlock, reader->getBlockSize());
        break;
    }
}
```

New code:
```cpp
} else {
    bool finished;
    if (yieldOnWait)
        finished = reader->checkFinishedNonBlocking(ctx->parserThread, confirmedBufferStart);
    else
        finished = reader->checkFinished(ctx->parserThread, confirmedBufferStart);

    if (finished) {
        if (reader->getRet() == Reader::REDO_CODE::YIELD) {
            // Save resume position for next call
            metadata->fileOffset = FileOffset(lwnConfirmedBlock, reader->getBlockSize());
            break;
        }
        if (reader->getRet() == Reader::REDO_CODE::FINISHED && nextScn == Scn::none() && reader->getNextScn() != Scn::none())
            nextScn = reader->getNextScn();
        if (reader->getRet() == Reader::REDO_CODE::STOPPED || reader->getRet() == Reader::REDO_CODE::OVERWRITTEN)
            metadata->fileOffset = FileOffset(lwnConfirmedBlock, reader->getBlockSize());
        break;
    }
}
```

#### How Resume Works After YIELD

When `parse()` is called again after YIELD:
1. `metadata->fileOffset` was set to `lwnConfirmedBlock` position (last fully-processed LWN)
2. At line 1253: `if (metadata->fileOffset > FileOffset::zero())` — enters resume path
3. At line 1258: `lwnConfirmedBlock = metadata->fileOffset.getBlock(reader->getBlockSize())` — resumes from correct block
4. At line 1264: `reader->setBufferStartEnd(...)` — tells Reader where Parser is starting
5. At line 1286: `reader->setStatusRead()` — idempotent, Reader already in READ status
6. Reader's `mainLoop()` kept running in its own OS thread, buffering new blocks
7. Parser processes whatever is in the buffer, yields again if caught up

**Note:** The initialization section of `parse()` (lines 1231-1286) runs again on re-entry. This includes resetlogs/activation checks and dump file handling. These are all idempotent. The key state (`lwnConfirmedBlock`, `confirmedBufferStart`) is derived from `metadata->fileOffset`, so resume is correct.

---

### 3.3 Step 3: Deferred Transaction Emission

**Files:** `src/parser/TransactionBuffer.h`, `src/parser/TransactionBuffer.cpp`, `src/parser/Parser.cpp`

#### TransactionBuffer.h — Add deferred commit structures (public section, near line 67)

```cpp
bool deferCommittedTransactions{false};

struct CommittedTransaction {
    Transaction* transaction;
    Scn commitScn;
    Scn lwnScn;
    Time lwnTimestamp;
    Seq sequence;
    uint16_t thread;
    bool rollback;
    bool shutdown;
};
std::vector<CommittedTransaction> committedPending;

void addCommittedPending(Transaction* transaction, Scn commitScn, Scn lwnScn,
                         Time lwnTimestamp, Seq sequence, uint16_t thread,
                         bool rollback, bool shutdown);
std::vector<CommittedTransaction> drainPendingBelow(Scn watermark);
```

#### TransactionBuffer.cpp — Implement methods

```cpp
void TransactionBuffer::addCommittedPending(Transaction* transaction, Scn commitScn,
                                            Scn lwnScn, Time lwnTimestamp, Seq sequence,
                                            uint16_t thread, bool rollback, bool shutdown) {
    committedPending.push_back({transaction, commitScn, lwnScn, lwnTimestamp,
                                sequence, thread, rollback, shutdown});
}

std::vector<TransactionBuffer::CommittedTransaction>
TransactionBuffer::drainPendingBelow(Scn watermark) {
    std::vector<CommittedTransaction> result;
    std::vector<CommittedTransaction> remaining;

    for (auto& ct : committedPending) {
        if (watermark != Scn::none() && ct.commitScn <= watermark)
            result.push_back(ct);
        else
            remaining.push_back(ct);
    }
    committedPending = std::move(remaining);

    // Sort by commitScn for proper emission order
    std::sort(result.begin(), result.end(),
        [](const CommittedTransaction& a, const CommittedTransaction& b) {
            return a.commitScn < b.commitScn;
        });
    return result;
}
```

#### Parser.cpp — Defer commit in appendToTransactionCommit() (line 793-841)

The current flow at lines 793-841 handles the commit:
1. Check `commitScn > firstDataScn` (is this new data?)
2. If `transaction->begin`: call `transaction->flush()`, update metrics, handle stopTransactions/shutdown
3. If not begin: log warning about partial transaction
4. Call `dropTransaction()`, `purge()`, `delete transaction`

**For RAC mode**, when `deferCommittedTransactions` is true, insert an early-return path before the `flush()` call:

```cpp
if ((transaction->commitScn > metadata->firstDataScn && !transaction->system) ||
    (transaction->commitScn > metadata->firstSchemaScn && transaction->system)) {
    if (transaction->begin) {
        if (transactionBuffer->deferCommittedTransactions) {
            // RAC mode: hold transaction for watermark-gated emission
            transactionBuffer->addCommittedPending(
                transaction, transaction->commitScn, lwnScn, lwnTimestamp,
                sequence, thread, transaction->rollback, transaction->shutdown);
            // Remove from active transaction map but DON'T delete yet
            transactionBuffer->dropTransaction(redoLogRecord1->xid, redoLogRecord1->conId);
            lastTransaction = nullptr;
            return;  // Early return — Replicator will flush later
        }

        // Original flush path (unchanged)
        transaction->flush(metadata, builder, lwnScn);
        // ... rest of existing code ...
```

**Key detail:** When deferring:
- `dropTransaction()` removes from active XID map (prevents further modification)
- Do NOT call `purge()` or `delete` — the Replicator owns the Transaction until flush
- `lastTransaction = nullptr` — prevents dangling pointer
- Early `return` — skip the cleanup at end of function

---

### 3.4 Step 4: Round-Robin Orchestrator in processOnlineRedoLogs()

**Files:** `src/replicator/Replicator.h`, `src/replicator/Replicator.cpp`

#### Replicator.h — Add RAC online redo state (protected section, near line 66)

```cpp
struct OnlineThreadState {
    Parser* activeParser{nullptr};
    Scn lastLwnScn{Scn::none()};  // SCN progress watermark for this thread
    bool yielded{false};           // Parser returned YIELD (waiting for data)
    bool finished{false};          // Parser returned FINISHED (log switch)
};
std::map<uint16_t, OnlineThreadState> onlineThreadStates;
Scn scnWatermark{Scn::none()};

void updateScnWatermark();
void emitWatermarkedTransactions();
```

#### Replicator.cpp — Rewrite processOnlineRedoLogs() (line 920-1032)

The existing single-instance code (lines 929-1031) is preserved verbatim inside an `if (threads.size() <= 1)` guard. The new RAC path is added as an `else` branch.

```cpp
bool Replicator::processOnlineRedoLogs() {
    bool logsProcessed = false;

    if (unlikely(ctx->isTraceSet(Ctx::TRACE::REDO)))
        ctx->logTrace(Ctx::TRACE::REDO, "checking online redo logs");
    updateResetlogs();
    updateOnlineLogs();

    // Determine if RAC (multiple redo threads)
    std::set<uint16_t> threads;
    for (Parser* onlineRedo : onlineRedoSet)
        threads.insert(onlineRedo->reader->getThread());

    if (threads.size() <= 1) {
        // ========== SINGLE-INSTANCE PATH (existing code, unchanged) ==========
        Parser* parser;
        // ... [lines 929-1031 verbatim] ...
        return logsProcessed;
    }

    // ========== RAC MULTI-THREAD PATH ==========
    transactionBuffer->deferCommittedTransactions = true;

    // Initialize per-thread state
    onlineThreadStates.clear();
    for (Parser* onlineRedo : onlineRedoSet) {
        const uint16_t thread = onlineRedo->reader->getThread();
        const Seq threadSeq = metadata->getSequence(thread);

        if (onlineRedo->reader->getSequence() == threadSeq &&
                (onlineRedo->reader->getNumBlocks() == Ctx::ZERO_BLK ||
                 metadata->getFileOffset(thread) <
                 FileOffset(onlineRedo->reader->getNumBlocks(),
                            onlineRedo->reader->getBlockSize()))) {
            onlineRedo->yieldOnWait = true;
            auto& state = onlineThreadStates[thread];
            if (state.activeParser == nullptr ||
                (onlineRedo->firstScn != Scn::none() &&
                 (state.activeParser->firstScn == Scn::none() ||
                  onlineRedo->firstScn < state.activeParser->firstScn)))
                state.activeParser = onlineRedo;
        }
    }

    if (onlineThreadStates.empty())
        return false;

    logsProcessed = true;

    while (!ctx->softShutdown) {
        bool allYielded = true;

        for (auto& [thread, state] : onlineThreadStates) {
            if (ctx->softShutdown)
                break;
            if (state.activeParser == nullptr)
                continue;

            // Reset yield flag to retry
            state.yielded = false;

            if (state.finished) {
                // Handle log switch: advance sequence, find new parser
                metadata->setNextSequence(thread);
                updateOnlineRedoLogData();
                updateOnlineLogs();

                state.activeParser = nullptr;
                state.finished = false;
                for (Parser* onlineRedo : onlineRedoSet) {
                    if (onlineRedo->reader->getThread() == thread &&
                        onlineRedo->reader->getSequence() == metadata->getSequence(thread)) {
                        onlineRedo->yieldOnWait = true;
                        state.activeParser = onlineRedo;
                        break;
                    }
                }
                if (state.activeParser == nullptr)
                    continue;
            }

            // Context switch: set per-thread metadata before parsing
            auto& ts = metadata->threadStates[thread];
            metadata->fileOffset = ts.fileOffset;
            metadata->sequence = ts.sequence;

            const Reader::REDO_CODE ret = state.activeParser->parse();

            // Save back per-thread state
            ts.fileOffset = metadata->fileOffset;
            ts.sequence = metadata->sequence;
            metadata->setFirstNextScn(thread, state.activeParser->firstScn,
                                      state.activeParser->nextScn);

            // Update thread's LWN progress
            if (state.activeParser->lwnScn != Scn::none())
                state.lastLwnScn = state.activeParser->lwnScn;

            switch (ret) {
                case Reader::REDO_CODE::YIELD:
                    state.yielded = true;
                    break;

                case Reader::REDO_CODE::FINISHED:
                    state.finished = true;
                    if (ctx->stopLogSwitches > 0) {
                        --ctx->stopLogSwitches;
                        if (ctx->stopLogSwitches == 0) {
                            ctx->info(0, "shutdown initiated by number of log switches");
                            ctx->stopSoft();
                        }
                    }
                    break;

                case Reader::REDO_CODE::OVERWRITTEN:
                    ctx->info(0, "online redo log (thread " + std::to_string(thread) +
                              ") overwritten, falling back to archives");
                    transactionBuffer->deferCommittedTransactions = false;
                    scnWatermark = Scn(UINT64_MAX);  // emit everything
                    emitWatermarkedTransactions();
                    return logsProcessed;

                case Reader::REDO_CODE::STOPPED:
                case Reader::REDO_CODE::OK:
                    break;

                default:
                    throw RuntimeException(10049, "read online redo log (thread " +
                        std::to_string(thread) + "), code: " +
                        std::to_string(static_cast<uint>(ret)));
            }

            if (!state.yielded)
                allYielded = false;
        }

        // Update watermark and emit eligible transactions
        updateScnWatermark();
        emitWatermarkedTransactions();

        if (ctx->softShutdown)
            break;

        // If all threads yielded (no new data), sleep briefly
        if (allYielded) {
            contextSet(CONTEXT::SLEEP);
            usleep(ctx->redoReadSleepUs);
            contextSet(CONTEXT::CPU);
            updateOnlineLogs();
        }
    }

    // Shutdown: flush remaining pending transactions
    transactionBuffer->deferCommittedTransactions = false;
    scnWatermark = Scn(UINT64_MAX);
    emitWatermarkedTransactions();

    return logsProcessed;
}
```

#### Replicator.cpp — Implement updateScnWatermark()

```cpp
void Replicator::updateScnWatermark() {
    Scn minScn = Scn::none();

    for (const auto& [thread, state] : onlineThreadStates) {
        if (state.activeParser == nullptr)
            continue;

        if (state.finished) {
            // Thread finished its log. Use nextScn as upper bound.
            Scn threadBound = state.activeParser->nextScn;
            if (threadBound == Scn::none())
                threadBound = state.lastLwnScn;
            if (threadBound != Scn::none()) {
                if (minScn == Scn::none() || threadBound < minScn)
                    minScn = threadBound;
            }
            continue;
        }

        if (state.lastLwnScn == Scn::none()) {
            // Thread hasn't processed any LWN yet — can't determine bound
            scnWatermark = Scn::none();
            return;
        }

        if (minScn == Scn::none() || state.lastLwnScn < minScn)
            minScn = state.lastLwnScn;
    }

    scnWatermark = minScn;
}
```

#### Replicator.cpp — Implement emitWatermarkedTransactions()

```cpp
void Replicator::emitWatermarkedTransactions() {
    if (scnWatermark == Scn::none())
        return;

    auto pending = transactionBuffer->drainPendingBelow(scnWatermark);

    for (auto& ct : pending) {
        ct.transaction->flush(metadata, builder, ct.lwnScn);
        ctx->parserThread->contextSet(Thread::CONTEXT::CPU);

        if (ctx->metrics != nullptr) {
            if (ct.rollback)
                ctx->metrics->emitTransactionsRollbackOut(1);
            else
                ctx->metrics->emitTransactionsCommitOut(1);
        }

        if (ctx->stopTransactions > 0 && metadata->isNewData(ct.lwnScn, builder->lwnIdx)) {
            --ctx->stopTransactions;
            if (ctx->stopTransactions == 0) {
                ctx->info(0, "shutdown started - exhausted number of transactions");
                ctx->stopSoft();
            }
        }

        if (ct.shutdown && metadata->isNewData(ct.lwnScn, builder->lwnIdx)) {
            ctx->info(0, "shutdown started - initiated by debug transaction at scn " +
                      ct.commitScn.toString());
            ctx->stopSoft();
        }

        ct.transaction->purge(ctx);
        delete ct.transaction;
    }
}
```

---

### 3.5 Step 5: Checkpoint Enhancement

**Files:** `src/metadata/Metadata.h`, `src/metadata/SerializerJson.cpp`

#### Metadata.h — Add lastLwnScn to ThreadState (line 110-115)

```cpp
struct ThreadState {
    Seq sequence{Seq::none()};
    FileOffset fileOffset;
    Scn firstScn{Scn::none()};
    Scn nextScn{Scn::none()};
    Scn lastLwnScn{Scn::none()};  // NEW: for SCN watermark on restart
};
```

#### Metadata.h — Extend checkpointThreads value type (line 139)

Current:
```cpp
std::map<uint16_t, std::pair<Seq, FileOffset>> checkpointThreads;
std::map<uint16_t, std::pair<Seq, FileOffset>> lastCheckpointThreads;
```

Change to include lastLwnScn:
```cpp
struct CheckpointThread {
    Seq sequence{Seq::none()};
    FileOffset fileOffset;
    Scn lastLwnScn{Scn::none()};
};
std::map<uint16_t, CheckpointThread> checkpointThreads;
std::map<uint16_t, CheckpointThread> lastCheckpointThreads;
```

Then update all references to `checkpointThreads` (they currently use `.first` for Seq and `.second` for FileOffset — change to `.sequence` and `.fileOffset`).

#### SerializerJson.cpp — Serialize lastLwnScn (line 70-72)

Current:
```cpp
ss << R"({"thread":)" << thr <<
        R"(,"seq":)" << seqOff.first.toString() <<
        R"(,"offset":)" << seqOff.second.toString() << "}";
```

New:
```cpp
ss << R"({"thread":)" << thr <<
        R"(,"seq":)" << ct.sequence.toString() <<
        R"(,"offset":)" << ct.fileOffset.toString() <<
        R"(,"lwn-scn":)" << ct.lastLwnScn.toString() << "}";
```

#### SerializerJson.cpp — Deserialize lastLwnScn (line 640-657)

After existing thread state restoration, add:
```cpp
if (threadsJson[i].HasMember("lwn-scn"))
    state.lastLwnScn = Ctx::getJsonFieldU64(fileName, threadsJson[i], "lwn-scn");
```

---

## 4. How the SCN Watermark Works

### The Problem

Two redo streams are internally SCN-ordered but interleave:
```
Thread 1: SCN 100, 150, 200, 300, 400, 500
Thread 2: SCN 120, 180, 250, 350, 450
```

If OLR reads Thread 1 up to SCN 400 and emits all its transactions, then reads Thread 2 and finds a transaction at SCN 250, the output is out of order.

### The Solution

**Watermark = min(lastLwnScn across all active threads)**

Each time a parser processes an LWN group, `lwnScn` is updated (`Parser.cpp` line 1318). This represents: "I have seen all data up to this SCN in my redo stream."

The watermark is the minimum across all threads. Any transaction with `commitScn ≤ watermark` can be safely emitted because **no thread can produce a new transaction with a lower commitScn**.

### Example

```
After round 1:  T1.lastLwnScn = 200, T2.lastLwnScn = 180
  Watermark = 180 → emit all pending transactions with commitScn ≤ 180

After round 2:  T1.lastLwnScn = 300, T2.lastLwnScn = 250
  Watermark = 250 → emit all pending with commitScn ≤ 250

After round 3:  T1.lastLwnScn = 300 (yielded), T2.lastLwnScn = 350
  Watermark = 300 → emit up to 300
```

### Idle Thread Behavior

If an Oracle instance is idle (no DML), LGWR still writes periodic checkpoint records (~every 3 seconds). These advance `lwnScn` without DML, so the watermark advances slowly. Worst case: ~3 second additional latency when one instance is idle.

If an instance is completely stopped, the watermark stalls at its last known SCN. This is correct — we can't guarantee no more transactions from that instance. Future enhancement: query `V$INSTANCE` and exclude stopped threads.

---

## 5. Per-Thread Metadata Context

**Important:** `metadata->fileOffset` and `metadata->sequence` are used by `Parser::parse()` at entry. In the RAC round-robin loop, these must be context-switched before/after each parser call:

```cpp
// Before parsing thread N:
auto& ts = metadata->threadStates[thread];
metadata->fileOffset = ts.fileOffset;
metadata->sequence = ts.sequence;

const Reader::REDO_CODE ret = state.activeParser->parse();

// After parsing: save back
ts.fileOffset = metadata->fileOffset;
ts.sequence = metadata->sequence;
```

This is only needed in RAC mode. Single-instance path uses `metadata->fileOffset` directly.

**TODO during implementation:** Verify all places where `metadata->fileOffset` and `metadata->sequence` are read/written during `parse()` and `checkpoint()` inside parse. Ensure per-thread state is correctly maintained.

---

## 6. Edge Cases

### 6.1 One Instance Down — Watermark Stalls

If one Oracle instance is stopped, its redo thread produces no new LWN records. The watermark stays at that thread's last `lastLwnScn`, preventing newer transactions from other threads from being emitted.

**Future mitigation:**
- Query `V$INSTANCE` periodically, exclude inactive instances
- Config option to specify active threads
- Timeout: if a thread hasn't progressed for N seconds, assume inactive

### 6.2 OVERWRITTEN on One Thread

If one thread's online redo is overwritten (log wrapped), fall back to archive processing for all threads. The `OVERWRITTEN` handler in the RAC path flushes all pending transactions and returns, letting the `run()` loop call `processArchivedRedoLogs()`.

### 6.3 Distributed (XA) Transactions

In Oracle RAC, distributed transactions can span instances. The COMMIT record appears in the coordinating instance's redo thread. OLR tracks transactions by XID (globally unique), so ops accumulate from whichever thread is parsed. The deferred flush by commitScn handles ordering correctly.

### 6.4 OLR Restart

On restart:
1. Per-thread checkpoint provides `{sequence, fileOffset, lastLwnScn}`
2. Each parser resumes from its checkpointed position
3. Watermark is re-derived from `lastLwnScn` values
4. `metadata->isNewData(scn, idx)` and Writer's `confirmedScn` prevent duplicate emission

### 6.5 System Transactions

System transactions (`transaction->system == true`) are compared against `metadata->firstSchemaScn`. They are deferred just like regular ones.

### 6.6 Transactions Without Begin

Partial transactions (`transaction->begin == false`) are logged as warnings and NOT deferred — same treatment as current code.

---

## 7. Files Changed Summary

| File | Changes |
|------|---------|
| `src/reader/Reader.h` | Add `YIELD` to enum, declare `checkFinishedNonBlocking()` |
| `src/reader/Reader.cpp` | Implement `checkFinishedNonBlocking()`, add REDO_MSG entry |
| `src/parser/Parser.h` | Add `bool yieldOnWait{false}` |
| `src/parser/Parser.cpp` | Non-blocking check when yieldOnWait; deferred commit path |
| `src/parser/TransactionBuffer.h` | Add `deferCommittedTransactions`, `CommittedTransaction`, pending queue |
| `src/parser/TransactionBuffer.cpp` | Implement `addCommittedPending()`, `drainPendingBelow()` |
| `src/replicator/Replicator.h` | Add `OnlineThreadState`, watermark, method declarations |
| `src/replicator/Replicator.cpp` | RAC path in `processOnlineRedoLogs()`, `updateScnWatermark()`, `emitWatermarkedTransactions()` |
| `src/metadata/Metadata.h` | Add `lastLwnScn` to `ThreadState`, change `checkpointThreads` type |
| `src/metadata/SerializerJson.cpp` | Serialize/deserialize `lastLwnScn` in checkpoint JSON |

---

## 8. Implementation Order

1. **Reader changes** (Step 1) — standalone, testable independently
2. **Parser yield mode** (Step 2) — depends on Step 1
3. **TransactionBuffer deferred commit** (Step 3) — standalone, parallel with Steps 1-2
4. **Replicator round-robin** (Step 4) — depends on Steps 1-3
5. **Checkpoint enhancement** (Step 5) — alongside Step 4
6. **Testing** — after all steps

---

## 9. Testing Plan

### 9.1 Build
```bash
GIDOLR=$(id -g) UIDOLR=$(id -u) docker compose run --rm build ./build-prod.sh
```

### 9.2 Single-Instance Regression
Run against any single-instance Oracle. Verify:
- `yieldOnWait` stays `false` (code takes single-instance path)
- Identical behavior to current code
- Online redo parsing works as before

### 9.3 RAC 2-Node Online Redo
Using deployed RAC VM:
1. Start OLR with new image
2. Insert DML on Node 1 (no log switch) → verify captured
3. Insert DML on Node 2 (no log switch) → verify captured
4. Verify output is in SCN order (commitScn monotonically increasing)
5. Check logs for YIELD activity (with trace/log-level enabled)

### 9.4 RAC Mixed Activity
1. Heavy DML on Node 1, Node 2 idle
2. Verify watermark advances (LGWR writes checkpoints on idle node)
3. Verify Node 1 transactions are emitted despite Node 2 being idle

### 9.5 Log Switch
1. DML on both nodes
2. Force log switch on Node 1: `ALTER SYSTEM SWITCH LOGFILE;`
3. Verify Node 1 transitions to new redo log, Node 2 unaffected
4. Continue DML, verify both threads captured

### 9.6 Restart
1. Stop OLR
2. Verify checkpoint contains per-thread `lastLwnScn` (inspect JSON)
3. Restart OLR
4. Insert more DML, verify no duplicates, correct resume from checkpoint
