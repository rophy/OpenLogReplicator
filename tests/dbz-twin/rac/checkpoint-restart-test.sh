#!/usr/bin/env bash
# checkpoint-restart-test.sh — Verify OLR resumes correctly from checkpoint after crash.
#
# Runs OLR against RAC, generates DML, waits for checkpoint, kills OLR,
# generates more DML while OLR is down, restarts OLR, verifies checkpoint
# resume, generates final DML, then compares OLR output against LogMiner.
#
# A successful test proves: no duplicates, no gaps after crash + restart,
# and that OLR resumes from checkpoint SCN (not start SCN).
#
# Usage: ./checkpoint-restart-test.sh [kill-count]
#   kill-count  Number of kill/restart cycles (default: 3)
#
# Prerequisites:
#   - RAC VM running with containers started
#   - OLR image loaded on VM (podman load)
#   - One-time setup done (./setup.sh)
#   - Local services running (docker compose up -d)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAC_ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$(cd "$RAC_ENV_DIR/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS_DIR="$TESTS_DIR/sql/scripts"
DBZ_TWIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

KILL_COUNT="${1:-3}"

# ---- RAC configuration (auto-detect VM IP) ----
source "$RAC_ENV_DIR/vm-env.sh"
OLR_IMAGE="${OLR_IMAGE:-docker.io/library/olr-dev:latest}"
RAC_NODE1="${RAC_NODE1:-racnodep1}"
RAC_NODE2="${RAC_NODE2:-racnodep2}"
ORACLE_SID1="${ORACLE_SID1:-ORCLCDB1}"
ORACLE_SID2="${ORACLE_SID2:-ORCLCDB2}"
DB_CONN1="${DB_CONN1:-olr_test/olr_test@//racnodep1:1521/ORCLPDB}"
DB_CONN2="${DB_CONN2:-olr_test/olr_test@//racnodep2:1521/ORCLPDB}"

OLR_CONTAINER="olr-debezium"
RECEIVER_URL="${RECEIVER_URL:-http://localhost:8080}"
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"

# ---- SSH helpers ----
_vm_sqlplus() {
    local node="$1" sid="$2" conn="$3" sql_file="$4"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $node su - oracle -c 'export ORACLE_SID=$sid; sqlplus -S \"$conn\" @$sql_file'"
}

_vm_copy_in() {
    local local_path="$1" container_path="$2" node="$3"
    local staging="/tmp/_chkpt_staging_$$"
    scp $_SSH_OPTS "$local_path" "${VM_USER}@${VM_HOST}:${staging}"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman cp ${staging} ${node}:${container_path}; rm -f ${staging}"
}

_exec_sysdba() {
    local sql_file="$1"
    local remote="/tmp/$(basename "$sql_file")"
    _vm_copy_in "$sql_file" "$remote" "$RAC_NODE1"
    _vm_sqlplus "$RAC_NODE1" "$ORACLE_SID1" "/ as sysdba" "$remote"
}

_exec_user() {
    local sql_file="$1"
    local node="${2:-$RAC_NODE1}" sid="${3:-$ORACLE_SID1}" conn="${4:-$DB_CONN1}"
    local remote="/tmp/$(basename "$sql_file")"
    _vm_copy_in "$sql_file" "$remote" "$node"
    local output
    output=$(_vm_sqlplus "$node" "$sid" "$conn" "$remote")
    # Check for Oracle errors in output
    if echo "$output" | grep -q "^ORA-\|^SP2-"; then
        echo "ERROR: SQL execution failed on $node:" >&2
        echo "$output" >&2
        return 1
    fi
    echo "$output"
}

_log_switch() {
    cat > "$WORK_DIR/log_switch.sql" <<'SQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH ALL LOGFILE;
BEGIN DBMS_SESSION.SLEEP(2); END;
/
EXIT
SQL
    _exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null
}

_start_olr() {
    echo "  Starting OLR..."
    # Ensure no leftover container
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman rm -f $OLR_CONTAINER 2>/dev/null; true"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman run -d --name $OLR_CONTAINER \
        --user 1000:54335 \
        -p 5000:5000 \
        -v /root/olr-debezium/config:/config:ro,Z \
        -v /root/olr-debezium/checkpoint:/olr-data/checkpoint:Z \
        -v /shared/redo:/shared/redo:ro \
        $OLR_IMAGE \
        -r -f /config/olr-config.json" > /dev/null
    sleep 3  # Let container initialize before polling logs

    # Wait for OLR to start processing (up to 3 min)
    for i in $(seq 1 90); do
        # Check if container exited
        local state
        state=$(ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
            "podman inspect $OLR_CONTAINER --format '{{.State.Status}}'" 2>/dev/null || echo "unknown")
        if [[ "$state" == "exited" || "$state" == "stopped" ]]; then
            echo "  ERROR: OLR container exited unexpectedly" >&2
            ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman logs $OLR_CONTAINER 2>&1 | tail -20" >&2
            return 1
        fi
        # Check readiness via podman logs on the VM itself (avoids SSH pipe issues)
        if ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
            "podman logs $OLR_CONTAINER 2>&1 | grep -q 'processing redo log'" 2>/dev/null; then
            echo "  OLR: ready (${i}x2s)"
            return 0
        fi
        sleep 2
    done
    echo "  ERROR: OLR did not become ready in 180s" >&2
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman logs $OLR_CONTAINER 2>&1 | tail -20" >&2
    return 1
}

_read_checkpoint_scn() {
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "cat /root/olr-debezium/checkpoint/ORCLCDB-chkpt.json 2>/dev/null | python3 -c \"
import sys,json
try:
    d=json.load(sys.stdin)
    print(d['scn'])
except: print('0')
\" 2>/dev/null" || echo "0"
}

_read_checkpoint() {
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "cat /root/olr-debezium/checkpoint/ORCLCDB-chkpt.json 2>/dev/null | python3 -c \"
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'scn={d[\"scn\"]}, idx={d.get(\"idx\",\"?\")}')
except: print('no checkpoint')
\" 2>/dev/null" || echo "no checkpoint"
}

_wait_for_checkpoint() {
    echo "  Waiting for OLR checkpoint (up to 30s)..."
    local prev_scn
    prev_scn=$(_read_checkpoint_scn)
    for i in $(seq 1 15); do
        sleep 2
        local cur_scn
        cur_scn=$(_read_checkpoint_scn)
        if [[ "$cur_scn" != "0" && "$cur_scn" != "$prev_scn" ]]; then
            echo "  Checkpoint written: scn=$cur_scn"
            return 0
        fi
        if [[ "$cur_scn" != "0" && "$prev_scn" == "0" ]]; then
            echo "  Checkpoint written: scn=$cur_scn"
            return 0
        fi
    done
    local final=$(_read_checkpoint)
    if [[ "$final" == "no checkpoint" ]]; then
        echo "  WARNING: No checkpoint after 30s"
        return 1
    else
        echo "  Checkpoint (unchanged): $final"
        return 0
    fi
}

_kill_olr() {
    local cycle="${1:-unknown}"
    echo "  Killing OLR (SIGKILL)..."
    # Preserve logs before removing container
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman logs $OLR_CONTAINER 2>&1" > "$WORK_DIR/olr-cycle-${cycle}.log" 2>/dev/null || true
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman stop -t0 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"
    echo "  Last checkpoint: $(_read_checkpoint)"
}

_run_dml() {
    local label="$1" batch="$2" node1_start="$3" node2_start="$4"
    local node1_end=$(( node1_start + batch - 1 ))
    local node2_end=$(( node2_start + batch - 1 ))

    cat > "$WORK_DIR/dml_node1.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  FOR i IN ${node1_start}..${node1_end} LOOP
    INSERT INTO olr_test.CHKPT_TEST (id, val, phase, node_id)
    VALUES (i, 'n1_${label}_' || i, '${label}', 1);
  END LOOP;
  COMMIT;
END;
/
EXIT
SQL

    cat > "$WORK_DIR/dml_node2.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  FOR i IN ${node2_start}..${node2_end} LOOP
    INSERT INTO olr_test.CHKPT_TEST (id, val, phase, node_id)
    VALUES (i, 'n2_${label}_' || i, '${label}', 2);
  END LOOP;
  COMMIT;
END;
/
EXIT
SQL

    _exec_user "$WORK_DIR/dml_node1.sql" "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1" > /dev/null
    _exec_user "$WORK_DIR/dml_node2.sql" "$RAC_NODE2" "$ORACLE_SID2" "$DB_CONN2" > /dev/null
    _log_switch

    echo "  $label: inserted $batch rows per node (IDs ${node1_start}-${node1_end} on node1, ${node2_start}-${node2_end} on node2)"
}

WORK_DIR=$(mktemp -d /tmp/chkpt_rac_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== OLR RAC Checkpoint/Restart Test ==="
echo "  Kill cycles: $KILL_COUNT"
echo ""

# ---- Stage 1: Verify services ----
echo "--- Stage 1: Verify services ---"

if ! curl -sf "$RECEIVER_URL/health" > /dev/null 2>&1; then
    echo "ERROR: Receiver not responding at $RECEIVER_URL" >&2
    exit 1
fi
echo "  Receiver: OK"

if ! ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec $RAC_NODE1 su - oracle -c 'export ORACLE_SID=$ORACLE_SID1; printf \"SELECT 1 FROM dual;\nEXIT;\n\" | sqlplus -S / as sysdba'" 2>/dev/null | grep -q "1"; then
    echo "ERROR: RAC Oracle not reachable on $VM_HOST" >&2
    exit 1
fi
echo "  Oracle RAC: OK"

if ! docker ps --format '{{.Names}}' | grep -q "^dbz-logminer$"; then
    echo "ERROR: Container dbz-logminer not running" >&2
    exit 1
fi
echo "  Debezium: OK"

# ---- Stage 2: Setup test table ----
echo ""
echo "--- Stage 2: Setup test table ---"

cat > "$WORK_DIR/setup.sql" <<'SQL'
SET FEEDBACK OFF
SET SERVEROUTPUT ON

BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.CHKPT_TEST PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/

CREATE TABLE olr_test.CHKPT_TEST (
  id        NUMBER PRIMARY KEY,
  val       VARCHAR2(200),
  phase     VARCHAR2(50),
  node_id   NUMBER(1),
  created   TIMESTAMP DEFAULT SYSTIMESTAMP
);
ALTER TABLE olr_test.CHKPT_TEST ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

DECLARE
  v_scn NUMBER;
BEGIN
  v_scn := DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER;
  DBMS_OUTPUT.PUT_LINE('CHKPT_SCN_START: ' || v_scn);
END;
/

EXIT
SQL
SETUP_OUT=$(_exec_user "$WORK_DIR/setup.sql")
echo "$SETUP_OUT"
_log_switch

# Stop existing OLR + clean checkpoint
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman stop -t5 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "mkdir -p /root/olr-debezium/config /root/olr-debezium/checkpoint"
scp $_SSH_OPTS "$SCRIPT_DIR/config/olr-config.json" "${VM_USER}@${VM_HOST}:/root/olr-debezium/config/"
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "rm -rf /root/olr-debezium/checkpoint/* && chown -R 1000:54335 /root/olr-debezium/checkpoint"
echo "  Checkpoint cleared"

# Restart Debezium connectors with clean state
echo "  Restarting Debezium connectors..."
cd "$SCRIPT_DIR"
for svc in dbz-logminer dbz-olr; do
    docker compose rm -sf "$svc" > /dev/null 2>&1
done
COMPOSE_PROJECT=$(docker compose config 2>/dev/null | grep -m1 'name:' | awk '{print $2}')
COMPOSE_PROJECT="${COMPOSE_PROJECT:-debezium}"
docker volume rm -f "${COMPOSE_PROJECT}_dbz-logminer-data" "${COMPOSE_PROJECT}_dbz-olr-data" > /dev/null 2>&1
docker compose up -d dbz-logminer dbz-olr > /dev/null 2>&1
cd - > /dev/null

# Wait for Debezium connectors — verify they're actually streaming
echo "  Waiting for Debezium connectors..."
for i in $(seq 1 60); do
    if docker logs dbz-logminer 2>&1 | tail -20 | grep -q "Starting streaming"; then
        echo "  LogMiner connector: streaming"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "ERROR: LogMiner connector did not start streaming in 120s" >&2
        docker logs dbz-logminer 2>&1 | tail -10 >&2
        exit 1
    fi
    sleep 2
done

# OLR adapter may not connect until OLR is started — just check it's running
for i in $(seq 1 10); do
    if docker ps --format '{{.Names}}' | grep -q "^dbz-olr-adapter$"; then
        echo "  OLR adapter: running"
        break
    fi
    sleep 2
done

# Reset receiver
curl -sf -X POST "$RECEIVER_URL/reset" > /dev/null

# ---- Stage 3: Kill/restart cycles ----
echo ""
echo "--- Stage 3: Kill/restart cycles ---"

BATCH=50
NEXT_N1=1000
NEXT_N2=2000

CHECKPOINT_VERIFIED=0

_start_olr
sleep 5  # Let OLR catch up to current SCN

for cycle in $(seq 1 "$KILL_COUNT"); do
    echo ""
    echo "  === Cycle $cycle / $KILL_COUNT ==="

    # Phase A: DML while OLR is running
    _run_dml "c${cycle}_running" "$BATCH" "$NEXT_N1" "$NEXT_N2"
    NEXT_N1=$(( NEXT_N1 + BATCH ))
    NEXT_N2=$(( NEXT_N2 + BATCH ))

    # Wait for OLR to write a checkpoint (interval-s: 10)
    _wait_for_checkpoint || true
    PRE_KILL_SCN=$(_read_checkpoint_scn)

    # Kill OLR
    _kill_olr "$cycle"

    # Phase B: DML while OLR is down
    _run_dml "c${cycle}_offline" "$BATCH" "$NEXT_N1" "$NEXT_N2"
    NEXT_N1=$(( NEXT_N1 + BATCH ))
    NEXT_N2=$(( NEXT_N2 + BATCH ))

    # Restart OLR — should resume from checkpoint
    _start_olr

    # Verify it resumed from checkpoint, not from start SCN
    POST_RESTART_SCN=$(_read_checkpoint_scn)
    if [[ "$PRE_KILL_SCN" != "0" && "$POST_RESTART_SCN" != "0" ]]; then
        echo "  Checkpoint resume: pre-kill scn=$PRE_KILL_SCN, post-restart scn=$POST_RESTART_SCN"
        if [[ "$POST_RESTART_SCN" -ge "$PRE_KILL_SCN" ]]; then
            echo "  PASS: OLR resumed from checkpoint (not start SCN)"
            CHECKPOINT_VERIFIED=$(( CHECKPOINT_VERIFIED + 1 ))
        else
            echo "  FAIL: Post-restart SCN ($POST_RESTART_SCN) < pre-kill SCN ($PRE_KILL_SCN)" >&2
        fi
    else
        echo "  WARNING: Could not verify checkpoint resume (pre=$PRE_KILL_SCN, post=$POST_RESTART_SCN)"
    fi

    # Wait for new checkpoint after processing offline DML (non-fatal if timeout)
    _wait_for_checkpoint || true
    sleep 5

    # Phase C: DML after restart
    _run_dml "c${cycle}_resumed" "$BATCH" "$NEXT_N1" "$NEXT_N2"
    NEXT_N1=$(( NEXT_N1 + BATCH ))
    NEXT_N2=$(( NEXT_N2 + BATCH ))
done

TOTAL_ROWS=$(( KILL_COUNT * 3 * BATCH * 2 ))
echo ""
echo "  Total rows inserted: $TOTAL_ROWS ($KILL_COUNT cycles x 3 phases x $BATCH rows x 2 nodes)"

# ---- Stage 4: Final DML + sentinel ----
echo ""
echo "--- Stage 4: Wait for processing + sentinel ---"

# Extra log switches to flush
_log_switch
sleep 5
_log_switch

cat > "$WORK_DIR/sentinel.sql" <<'SQL'
DELETE FROM DEBEZIUM_SENTINEL;
INSERT INTO DEBEZIUM_SENTINEL VALUES (1, 'checkpoint-restart-test');
COMMIT;
EXIT;
SQL
_exec_user "$WORK_DIR/sentinel.sql" > /dev/null
echo "  Sentinel inserted"
_log_switch

# Wait for both connectors to see sentinel
SENTINEL_OK=true
START_TIME=$(date +%s)
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $POLL_TIMEOUT ]]; then
        echo ""
        echo "ERROR: Timeout after ${POLL_TIMEOUT}s waiting for events" >&2
        STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
        echo "  Final status: $STATUS" >&2
        SENTINEL_OK=false
        break
    fi

    STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
    LM_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_sentinel',False))" 2>/dev/null || echo "False")
    OLR_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_sentinel',False))" 2>/dev/null || echo "False")
    LM_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_count',0))" 2>/dev/null || echo "0")
    OLR_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_count',0))" 2>/dev/null || echo "0")

    printf "\r  [%3ds] LogMiner: %s events (sentinel: %s) | OLR: %s events (sentinel: %s)   " \
        "$ELAPSED" "$LM_COUNT" "$LM_SENTINEL" "$OLR_COUNT" "$OLR_SENTINEL"

    if [[ "$LM_SENTINEL" == "True" && "$OLR_SENTINEL" == "True" ]]; then
        echo ""
        echo "  Both connectors have processed all events"
        break
    fi

    sleep 2
done

# ---- Stage 5: Compare outputs ----
echo ""
echo "--- Stage 5: Compare LogMiner vs OLR ---"

LM_FILE="$SCRIPT_DIR/output/logminer.jsonl"
OLR_FILE="$SCRIPT_DIR/output/olr.jsonl"

COMPARE_RESULT=0
if [[ "$SENTINEL_OK" != "true" ]]; then
    echo "  FAIL: Sentinel timeout — comparison unreliable"
    COMPARE_RESULT=1
elif [[ ! -s "$LM_FILE" ]]; then
    echo "  FAIL: LogMiner output is empty" >&2
    COMPARE_RESULT=1
elif [[ ! -s "$OLR_FILE" ]]; then
    echo "  FAIL: OLR output is empty" >&2
    COMPARE_RESULT=1
else
    # Sort both files by content before comparing — RAC transactions from
    # different nodes may arrive in different SCN order between LogMiner and OLR.
    python3 -c "
import json, sys
records = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            records.append(json.loads(line))
records.sort(key=lambda r: json.dumps(r.get('after') or r.get('before') or {}, sort_keys=True))
with open(sys.argv[2], 'w') as f:
    for r in records:
        f.write(json.dumps(r) + '\n')
" "$LM_FILE" "$WORK_DIR/logminer-sorted.jsonl"

    python3 -c "
import json, sys
records = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            records.append(json.loads(line))
records.sort(key=lambda r: json.dumps(r.get('after') or r.get('before') or {}, sort_keys=True))
with open(sys.argv[2], 'w') as f:
    for r in records:
        f.write(json.dumps(r) + '\n')
" "$OLR_FILE" "$WORK_DIR/olr-sorted.jsonl"

    if python3 "$DBZ_TWIN_DIR/compare-debezium.py" "$WORK_DIR/logminer-sorted.jsonl" "$WORK_DIR/olr-sorted.jsonl"; then
        echo "  Data accuracy: PASS"
    else
        echo "  Data accuracy: FAIL"
        COMPARE_RESULT=1
    fi
fi

# ---- Stage 6: Duplicate/gap check ----
echo ""
echo "--- Stage 6: Duplicate and gap analysis ---"

# Extract CHKPT_TEST insert IDs from OLR output
# Debezium NUMBER fields are structs: {"scale": 0, "value": "base64"}
DUP_RESULT=0
python3 - "$OLR_FILE" "$TOTAL_ROWS" <<'PYEOF' || DUP_RESULT=$?
import json, sys, base64

olr_file = sys.argv[1]
expected_total = int(sys.argv[2])

def decode_debezium_number(val):
    """Decode Debezium NUMBER struct {scale, value} to int."""
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, dict) and "value" in val:
        raw = base64.b64decode(val["value"])
        n = int.from_bytes(raw, byteorder="big", signed=True)
        scale = val.get("scale", 0)
        if scale > 0:
            return n / (10 ** scale)
        return n
    return None

ids = []
with open(olr_file) as f:
    for line in f:
        try:
            event = json.loads(line)
            payload = event.get("payload", event)
            if payload.get("op") != "c":
                continue
            after = payload.get("after", {})
            source = payload.get("source", {})
            if source.get("table") != "CHKPT_TEST":
                continue
            row_id = decode_debezium_number(after.get("ID"))
            if row_id is not None:
                ids.append(int(row_id))
        except (json.JSONDecodeError, ValueError, KeyError):
            continue

ids.sort()
unique_ids = sorted(set(ids))
duplicates = len(ids) - len(unique_ids)

print(f"  Total CHKPT_TEST inserts captured: {len(ids)}")
print(f"  Unique IDs: {len(unique_ids)}")
print(f"  Duplicates: {duplicates}")
print(f"  Expected rows: {expected_total}")

if len(ids) == 0:
    print("  FAIL: No CHKPT_TEST insert events found in OLR output")
    sys.exit(1)

if duplicates > 0:
    from collections import Counter
    counts = Counter(ids)
    dup_ids = sorted([k for k, v in counts.items() if v > 1])
    print(f"  Duplicate IDs: {dup_ids[:20]}{'...' if len(dup_ids) > 20 else ''}")
    print("  FAIL: Duplicates found")
    sys.exit(1)

if len(unique_ids) < expected_total:
    print(f"  FAIL: Captured {len(unique_ids)} < expected {expected_total} (data gap)")
    sys.exit(1)

print("  PASS: No duplicates or gaps detected")
PYEOF

# ---- Stage 7: OLR error/ASAN check ----
echo ""
echo "--- Stage 7: OLR error checks ---"
OLR_ERROR_RESULT=0
# Save final container logs and combine with per-cycle logs
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman logs $OLR_CONTAINER 2>&1" > "$WORK_DIR/olr-cycle-final.log" 2>/dev/null || true
cat "$WORK_DIR"/olr-cycle-*.log > "$WORK_DIR/olr-all.log" 2>/dev/null || true

if grep -q "AddressSanitizer\|ABORTING" "$WORK_DIR/olr-all.log"; then
    echo "  FAIL: ASAN errors detected"
    grep -A5 "AddressSanitizer" "$WORK_DIR/olr-all.log" | head -10
    OLR_ERROR_RESULT=1
else
    echo "  PASS: No ASAN errors"
fi

if grep -q "ERROR 50022\|duplicate SYS\." "$WORK_DIR/olr-all.log"; then
    echo "  FAIL: OLR duplicate/schema errors detected"
    grep "ERROR 50022\|duplicate SYS\." "$WORK_DIR/olr-all.log" | head -5
    OLR_ERROR_RESULT=1
else
    echo "  PASS: No OLR duplicate/schema errors"
fi

# ---- Summary ----
echo ""
echo "========================================"
echo "  Checkpoint/Restart Test Summary"
echo "========================================"
echo "  Kill cycles:    $KILL_COUNT"
echo "  Total rows:     $TOTAL_ROWS"
echo "  Phases per cycle: DML -> checkpoint -> kill -> offline DML -> restart -> verify -> DML"
echo "  Checkpoint resume verified: $CHECKPOINT_VERIFIED / $KILL_COUNT cycles"

CHKPT_RESULT=0
if [[ $CHECKPOINT_VERIFIED -lt 1 ]]; then
    echo "  WARNING: Checkpoint resume was never verified"
    CHKPT_RESULT=1
fi

if [[ $COMPARE_RESULT -eq 0 && $DUP_RESULT -eq 0 && $CHKPT_RESULT -eq 0 && $OLR_ERROR_RESULT -eq 0 ]]; then
    echo "  Accuracy:       PASS"
    echo "  Duplicates:     PASS"
    echo "  Checkpoint:     PASS ($CHECKPOINT_VERIFIED/$KILL_COUNT)"
    echo "  OLR errors:     PASS"
    echo ""
    echo "=== PASS: Checkpoint/restart test completed ==="
else
    echo "  Accuracy:       $([ $COMPARE_RESULT -eq 0 ] && echo PASS || echo FAIL)"
    echo "  Duplicates:     $([ $DUP_RESULT -eq 0 ] && echo PASS || echo FAIL)"
    echo "  Checkpoint:     $([ $CHKPT_RESULT -eq 0 ] && echo "PASS ($CHECKPOINT_VERIFIED/$KILL_COUNT)" || echo FAIL)"
    echo "  OLR errors:     $([ $OLR_ERROR_RESULT -eq 0 ] && echo PASS || echo FAIL)"
    echo ""
    echo "=== FAIL: Checkpoint/restart test failed ==="
    echo "  LogMiner output: $LM_FILE"
    echo "  OLR output:      $OLR_FILE"
fi

exit $(( COMPARE_RESULT + DUP_RESULT + CHKPT_RESULT + OLR_ERROR_RESULT ))
