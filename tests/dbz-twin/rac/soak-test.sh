#!/usr/bin/env bash
# soak-test.sh — Sustained OLR soak test with memory monitoring + data accuracy.
#
# Runs OLR in online mode against RAC for a specified duration, each round
# doing randomized DML (INSERT/UPDATE/DELETE mix, varying batch sizes,
# occasional rollbacks) on both nodes + log switch. Monitors OLR container
# memory at each round. After all rounds, compares cumulative OLR output
# against LogMiner via the Debezium twin-test infrastructure.
#
# Usage: ./soak-test.sh [duration-minutes]
#   duration-minutes  How long to run DML rounds (default: 30)
#
# Prerequisites:
#   - RAC VM running with containers started
#   - OLR image loaded on VM (podman load)
#   - One-time setup done (./setup.sh)
#   - Local services running (make up)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBZ_TWIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$(cd "$DBZ_TWIN_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS_DIR="$TESTS_DIR/sql/scripts"
RAC_ENV_DIR="$TESTS_DIR/environments/rac"

DURATION_MINUTES="${1:-30}"
DURATION_SECONDS=$(( DURATION_MINUTES * 60 ))

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
POLL_TIMEOUT="${POLL_TIMEOUT:-180}"

# ---- SSH helpers ----
_vm_sqlplus() {
    local node="$1" sid="$2" conn="$3" sql_file="$4"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $node su - oracle -c 'export ORACLE_SID=$sid; sqlplus -S \"$conn\" @$sql_file'"
}

_vm_copy_in() {
    local local_path="$1" container_path="$2" node="$3"
    local staging="/tmp/_soak_staging_$$"
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
    _vm_sqlplus "$node" "$sid" "$conn" "$remote"
}

# Get OLR process memory (RSS in MB) — reads actual OLR process, not shell wrapper
_olr_memory_mb() {
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $OLR_CONTAINER sh -c 'cat /proc/\$(pgrep -f OpenLogReplicator | head -1)/status 2>/dev/null | grep VmRSS | awk \"{printf \\\"%.0f\\\", \\\$2/1024}\"'" 2>/dev/null || echo "N/A"
}

WORK_DIR=$(mktemp -d /tmp/soak_rac_XXXXXX)
MEMORY_LOG="$WORK_DIR/memory.csv"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== OLR RAC Soak Test ==="
echo "  Duration: ${DURATION_MINUTES} minutes"
echo "  DML: randomized INSERT/UPDATE/DELETE mix on 3 tables"
echo "  Memory log: $MEMORY_LOG"
echo ""

# ---- Stage 1: Verify services ----
echo "--- Stage 1: Verify services ---"

if ! curl -sf "$RECEIVER_URL/health" > /dev/null 2>&1; then
    echo "ERROR: Receiver not responding at $RECEIVER_URL" >&2
    echo "Run: make -C tests/environments/rac/debezium up" >&2
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

# ---- Stage 2: Create soak test tables + start OLR ----
echo ""
echo "--- Stage 2: Setup tables and start OLR ---"

# Three tables with different column profiles to exercise different code paths
cat > "$WORK_DIR/setup.sql" <<'SQL'
SET SERVEROUTPUT ON
SET FEEDBACK OFF

-- Table 1: Simple key-value with VARCHAR2
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.SOAK_KV PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.SOAK_KV (
  id        NUMBER PRIMARY KEY,
  val       VARCHAR2(200),
  amount    NUMBER(12,2),
  flag      NUMBER(1) DEFAULT 0,
  updated   TIMESTAMP DEFAULT SYSTIMESTAMP
);
ALTER TABLE olr_test.SOAK_KV ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Table 2: Wide row with various numeric types
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.SOAK_WIDE PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.SOAK_WIDE (
  id        NUMBER PRIMARY KEY,
  col_int   NUMBER(10),
  col_big   NUMBER(18),
  col_dec   NUMBER(15,4),
  col_str1  VARCHAR2(100),
  col_str2  VARCHAR2(100),
  col_date  DATE DEFAULT SYSDATE,
  col_ts    TIMESTAMP DEFAULT SYSTIMESTAMP
);
ALTER TABLE olr_test.SOAK_WIDE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Table 3: CLOB for LOB processing paths
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.SOAK_LOB PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.SOAK_LOB (
  id        NUMBER PRIMARY KEY,
  label     VARCHAR2(50),
  content   CLOB
);
ALTER TABLE olr_test.SOAK_LOB ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

DECLARE
  v_scn NUMBER;
BEGIN
  v_scn := DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER;
  DBMS_OUTPUT.PUT_LINE('SOAK_SCN_START: ' || v_scn);
END;
/

EXIT
SQL
SETUP_OUT=$(_exec_user "$WORK_DIR/setup.sql")
echo "$SETUP_OUT"

# Force log switch
cat > "$WORK_DIR/log_switch.sql" <<'SQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH ALL LOGFILE;
BEGIN DBMS_SESSION.SLEEP(2); END;
/
EXIT
SQL
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

# Stop existing OLR
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman stop -t5 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"

# Deploy OLR config
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "mkdir -p /root/olr-debezium/config /root/olr-debezium/checkpoint"
scp $_SSH_OPTS "$SCRIPT_DIR/config/olr-config.json" "${VM_USER}@${VM_HOST}:/root/olr-debezium/config/"
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "rm -rf /root/olr-debezium/checkpoint/* && chown -R 1000:54335 /root/olr-debezium/checkpoint"

# Start OLR — needs RAC public network to reach SCAN VIPs
echo "  Starting OLR on RAC VM..."
SCAN_IP=$(ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec racnodep1 getent hosts racnodepc1-scan 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null)
if [[ -z "$SCAN_IP" ]]; then
    echo "ERROR: Failed to resolve racnodepc1-scan IP from RAC VM" >&2
    exit 1
fi
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman run -d --name $OLR_CONTAINER \
    --user 1000:54335 \
    --network rac_pub1_nw \
    --add-host racnodepc1-scan:${SCAN_IP} \
    -p 5000:5000 \
    -v /root/olr-debezium/config:/config:ro,Z \
    -v /root/olr-debezium/checkpoint:/olr-data/checkpoint:Z \
    -v /shared/redo:/shared/redo:ro \
    $OLR_IMAGE \
    -r -f /config/olr-config.json" > /dev/null

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

# Wait for OLR
echo "  Waiting for OLR to initialize..."
for i in $(seq 1 60); do
    if ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman logs $OLR_CONTAINER 2>&1 | tail -5" 2>/dev/null | grep -q "processing redo log"; then
        break
    fi
    sleep 2
done
echo "  OLR: ready"

# Wait for Debezium connectors
echo "  Waiting for Debezium connectors..."
for i in $(seq 1 30); do
    if docker logs dbz-olr-adapter 2>&1 | tail -10 | grep -q "streaming client started successfully\|Starting streaming"; then
        break
    fi
    sleep 2
done
for i in $(seq 1 30); do
    if docker logs dbz-logminer 2>&1 | tail -10 | grep -q "Starting streaming"; then
        break
    fi
    sleep 2
done
echo "  Connectors ready"

# Reset receiver
curl -sf -X POST "$RECEIVER_URL/reset" > /dev/null

# Initial memory reading
INIT_MEM=$(_olr_memory_mb)
echo ""
echo "  Initial OLR memory: ${INIT_MEM} MB"

# ---- Stage 3: Run DML rounds with memory monitoring ----
echo ""
echo "--- Stage 3: Running DML rounds for ${DURATION_MINUTES} minutes ---"
echo "round,elapsed_s,memory_mb,ops_this_round,total_ops" > "$MEMORY_LOG"
echo "0,0,${INIT_MEM},0,0" >> "$MEMORY_LOG"

SOAK_START=$(date +%s)
TOTAL_OPS=0
ROUND=0
NEXT_ID_KV=1
NEXT_ID_WIDE=1
NEXT_ID_LOB=1

# Seed the PRNG (bash $RANDOM is per-process)
RANDOM=$$

while true; do
    ELAPSED=$(( $(date +%s) - SOAK_START ))
    if [[ $ELAPSED -ge $DURATION_SECONDS ]]; then
        break
    fi

    ROUND=$(( ROUND + 1 ))
    ROUND_OPS=0

    # Randomize which operations this round does:
    #   - batch size: 5-80 rows
    #   - operation mix: INSERT-heavy early, more UPDATE/DELETE as data accumulates
    #   - which node runs what
    #   - occasional rollback round (~10%)
    #   - occasional LOB round (~20%)
    BATCH_SIZE=$(( RANDOM % 76 + 5 ))  # 5-80
    DO_ROLLBACK=$(( RANDOM % 10 ))     # 0 = rollback round (10%)
    DO_LOB=$(( RANDOM % 5 ))           # 0 = LOB round (20%)
    OP_DICE=$(( RANDOM % 100 ))

    # Decide operation type based on accumulated data
    if [[ $NEXT_ID_KV -le 50 ]]; then
        # Not enough rows yet — always INSERT
        OP_TYPE="insert"
    elif [[ $OP_DICE -lt 40 ]]; then
        OP_TYPE="insert"
    elif [[ $OP_DICE -lt 70 ]]; then
        OP_TYPE="update"
    elif [[ $OP_DICE -lt 85 ]]; then
        OP_TYPE="mixed"
    else
        OP_TYPE="delete"
    fi

    # Decide which node does what (swap every ~third round)
    if [[ $(( RANDOM % 3 )) -eq 0 ]]; then
        PRIMARY_NODE="$RAC_NODE2"; PRIMARY_SID="$ORACLE_SID2"; PRIMARY_CONN="$DB_CONN2"
        SECONDARY_NODE="$RAC_NODE1"; SECONDARY_SID="$ORACLE_SID1"; SECONDARY_CONN="$DB_CONN1"
    else
        PRIMARY_NODE="$RAC_NODE1"; PRIMARY_SID="$ORACLE_SID1"; PRIMARY_CONN="$DB_CONN1"
        SECONDARY_NODE="$RAC_NODE2"; SECONDARY_SID="$ORACLE_SID2"; SECONDARY_CONN="$DB_CONN2"
    fi

    # ---- Generate SQL for primary node ----
    cat > "$WORK_DIR/dml_primary.sql" <<SQLHEADER
SET FEEDBACK OFF
SQLHEADER

    case "$OP_TYPE" in
        insert)
            cat >> "$WORK_DIR/dml_primary.sql" <<SQL
BEGIN
  FOR i IN ${NEXT_ID_KV}..$(( NEXT_ID_KV + BATCH_SIZE - 1 )) LOOP
    INSERT INTO olr_test.SOAK_KV (id, val, amount, flag)
    VALUES (i, 'r${ROUND}_' || DBMS_RANDOM.STRING('x', TRUNC(DBMS_RANDOM.VALUE(5,50))),
            ROUND(DBMS_RANDOM.VALUE(-99999, 99999), 2),
            TRUNC(DBMS_RANDOM.VALUE(0, 2)));
  END LOOP;
  COMMIT;
END;
/
SQL
            NEXT_ID_KV=$(( NEXT_ID_KV + BATCH_SIZE ))
            ROUND_OPS=$(( ROUND_OPS + BATCH_SIZE ))
            ;;
        update)
            # Update random subset of existing rows
            UPD_START=$(( RANDOM % (NEXT_ID_KV - 1) + 1 ))
            UPD_COUNT=$(( BATCH_SIZE > (NEXT_ID_KV - UPD_START) ? (NEXT_ID_KV - UPD_START) : BATCH_SIZE ))
            [[ $UPD_COUNT -lt 1 ]] && UPD_COUNT=1
            cat >> "$WORK_DIR/dml_primary.sql" <<SQL
BEGIN
  FOR i IN ${UPD_START}..$(( UPD_START + UPD_COUNT - 1 )) LOOP
    UPDATE olr_test.SOAK_KV
    SET val = 'upd_r${ROUND}_' || DBMS_RANDOM.STRING('x', TRUNC(DBMS_RANDOM.VALUE(3,30))),
        amount = ROUND(DBMS_RANDOM.VALUE(-99999, 99999), 2),
        flag = 1 - flag,
        updated = SYSTIMESTAMP
    WHERE id = i;
  END LOOP;
  COMMIT;
END;
/
SQL
            ROUND_OPS=$(( ROUND_OPS + UPD_COUNT ))
            ;;
        mixed)
            # Insert some + update some in same transaction
            INS_COUNT=$(( BATCH_SIZE / 2 ))
            UPD_START=$(( RANDOM % (NEXT_ID_KV - 1) + 1 ))
            UPD_COUNT=$(( BATCH_SIZE - INS_COUNT ))
            [[ $UPD_COUNT -gt $(( NEXT_ID_KV - UPD_START )) ]] && UPD_COUNT=$(( NEXT_ID_KV - UPD_START ))
            [[ $UPD_COUNT -lt 1 ]] && UPD_COUNT=1
            cat >> "$WORK_DIR/dml_primary.sql" <<SQL
BEGIN
  -- Inserts
  FOR i IN ${NEXT_ID_KV}..$(( NEXT_ID_KV + INS_COUNT - 1 )) LOOP
    INSERT INTO olr_test.SOAK_KV (id, val, amount, flag)
    VALUES (i, 'mix_r${ROUND}_' || DBMS_RANDOM.STRING('a', TRUNC(DBMS_RANDOM.VALUE(5,40))),
            ROUND(DBMS_RANDOM.VALUE(0, 50000), 2), 0);
  END LOOP;
  -- Updates
  FOR i IN ${UPD_START}..$(( UPD_START + UPD_COUNT - 1 )) LOOP
    UPDATE olr_test.SOAK_KV
    SET amount = amount + ROUND(DBMS_RANDOM.VALUE(-100, 100), 2),
        updated = SYSTIMESTAMP
    WHERE id = i;
  END LOOP;
  COMMIT;
END;
/
SQL
            NEXT_ID_KV=$(( NEXT_ID_KV + INS_COUNT ))
            ROUND_OPS=$(( ROUND_OPS + INS_COUNT + UPD_COUNT ))
            ;;
        delete)
            # Delete a random range then re-insert (so IDs don't run out)
            DEL_START=$(( RANDOM % (NEXT_ID_KV / 2 + 1) + 1 ))
            DEL_COUNT=$(( BATCH_SIZE > 20 ? 20 : BATCH_SIZE ))
            [[ $DEL_COUNT -gt $(( NEXT_ID_KV - DEL_START )) ]] && DEL_COUNT=$(( NEXT_ID_KV - DEL_START ))
            [[ $DEL_COUNT -lt 1 ]] && DEL_COUNT=1
            cat >> "$WORK_DIR/dml_primary.sql" <<SQL
BEGIN
  DELETE FROM olr_test.SOAK_KV WHERE id BETWEEN ${DEL_START} AND $(( DEL_START + DEL_COUNT - 1 ));
  COMMIT;
END;
/
SQL
            ROUND_OPS=$(( ROUND_OPS + DEL_COUNT ))
            ;;
    esac

    echo "EXIT" >> "$WORK_DIR/dml_primary.sql"

    # ---- Generate SQL for secondary node (always SOAK_WIDE table) ----
    WIDE_BATCH=$(( RANDOM % 30 + 5 ))  # 5-34
    cat > "$WORK_DIR/dml_secondary.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  FOR i IN ${NEXT_ID_WIDE}..$(( NEXT_ID_WIDE + WIDE_BATCH - 1 )) LOOP
    INSERT INTO olr_test.SOAK_WIDE (id, col_int, col_big, col_dec, col_str1, col_str2)
    VALUES (i,
            TRUNC(DBMS_RANDOM.VALUE(-2147483648, 2147483647)),
            TRUNC(DBMS_RANDOM.VALUE(-1e15, 1e15)),
            ROUND(DBMS_RANDOM.VALUE(-99999, 99999), 4),
            DBMS_RANDOM.STRING('p', TRUNC(DBMS_RANDOM.VALUE(10, 80))),
            DBMS_RANDOM.STRING('a', TRUNC(DBMS_RANDOM.VALUE(5, 50))));
  END LOOP;
  COMMIT;
END;
/
EXIT
SQL
    NEXT_ID_WIDE=$(( NEXT_ID_WIDE + WIDE_BATCH ))
    ROUND_OPS=$(( ROUND_OPS + WIDE_BATCH ))

    # ---- Optional: LOB round on primary node ----
    if [[ $DO_LOB -eq 0 ]]; then
        LOB_COUNT=$(( RANDOM % 5 + 1 ))  # 1-5 LOB rows
        cat > "$WORK_DIR/dml_lob.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  FOR i IN ${NEXT_ID_LOB}..$(( NEXT_ID_LOB + LOB_COUNT - 1 )) LOOP
    INSERT INTO olr_test.SOAK_LOB (id, label, content)
    VALUES (i, 'lob_r${ROUND}_' || i,
            RPAD('CLOB-round${ROUND}-', TRUNC(DBMS_RANDOM.VALUE(100, 4000)), 'X'));
  END LOOP;
  COMMIT;
END;
/
EXIT
SQL
        NEXT_ID_LOB=$(( NEXT_ID_LOB + LOB_COUNT ))
        ROUND_OPS=$(( ROUND_OPS + LOB_COUNT ))
    fi

    # ---- Optional: Rollback round — do DML then rollback on primary ----
    if [[ $DO_ROLLBACK -eq 0 && $NEXT_ID_KV -gt 10 ]]; then
        cat > "$WORK_DIR/dml_rollback.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  UPDATE olr_test.SOAK_KV SET val = 'WILL_ROLLBACK' WHERE id BETWEEN 1 AND 5;
  ROLLBACK;
END;
/
EXIT
SQL
    fi

    # ---- Execute ----
    _exec_user "$WORK_DIR/dml_primary.sql" "$PRIMARY_NODE" "$PRIMARY_SID" "$PRIMARY_CONN" > /dev/null
    _exec_user "$WORK_DIR/dml_secondary.sql" "$SECONDARY_NODE" "$SECONDARY_SID" "$SECONDARY_CONN" > /dev/null

    if [[ $DO_LOB -eq 0 && -f "$WORK_DIR/dml_lob.sql" ]]; then
        _exec_user "$WORK_DIR/dml_lob.sql" "$PRIMARY_NODE" "$PRIMARY_SID" "$PRIMARY_CONN" > /dev/null
    fi

    if [[ $DO_ROLLBACK -eq 0 && -f "$WORK_DIR/dml_rollback.sql" ]]; then
        _exec_user "$WORK_DIR/dml_rollback.sql" "$SECONDARY_NODE" "$SECONDARY_SID" "$SECONDARY_CONN" > /dev/null
    fi

    TOTAL_OPS=$(( TOTAL_OPS + ROUND_OPS ))

    # Force log switch every round
    _exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

    # Record memory
    ELAPSED=$(( $(date +%s) - SOAK_START ))
    MEM=$(_olr_memory_mb)
    echo "$ROUND,$ELAPSED,$MEM,$ROUND_OPS,$TOTAL_OPS" >> "$MEMORY_LOG"

    printf "\r  Round %3d | %4ds/%ds | OLR: %s MB | ops: %d (+%d) | %s  " \
        "$ROUND" "$ELAPSED" "$DURATION_SECONDS" "$MEM" "$TOTAL_OPS" "$ROUND_OPS" "$OP_TYPE"

    # Brief pause
    sleep 2

    # Clean up optional files
    rm -f "$WORK_DIR/dml_lob.sql" "$WORK_DIR/dml_rollback.sql"
done

echo ""
echo "  DML complete: $TOTAL_OPS operations across $ROUND rounds"

# ---- Stage 4: Insert sentinel + wait for completion ----
echo ""
echo "--- Stage 4: Insert sentinel and wait for processing ---"

# Extra log switches to flush everything
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null
sleep 3
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

cat > "$WORK_DIR/sentinel.sql" <<'SQL'
DELETE FROM DEBEZIUM_SENTINEL;
INSERT INTO DEBEZIUM_SENTINEL VALUES (1, 'soak-test');
COMMIT;
EXIT;
SQL
_exec_user "$WORK_DIR/sentinel.sql" > /dev/null
echo "  Sentinel inserted"

_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

# Wait for both connectors
START_TIME=$(date +%s)
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $POLL_TIMEOUT ]]; then
        echo ""
        echo "ERROR: Timeout after ${POLL_TIMEOUT}s waiting for events" >&2
        STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
        echo "  Final status: $STATUS" >&2
        break
    fi

    STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
    LM_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_sentinel',False))" 2>/dev/null || echo "False")
    OLR_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_sentinel',False))" 2>/dev/null || echo "False")
    LM_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_count',0))" 2>/dev/null || echo "0")
    OLR_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_count',0))" 2>/dev/null || echo "0")

    printf "\r  [%3ds] LogMiner: %s events (sentinel: %s) | OLR: %s events (sentinel: %s)" \
        "$ELAPSED" "$LM_COUNT" "$LM_SENTINEL" "$OLR_COUNT" "$OLR_SENTINEL"

    if [[ "$LM_SENTINEL" == "True" && "$OLR_SENTINEL" == "True" ]]; then
        echo ""
        echo "  Both connectors have processed all events"
        break
    fi

    sleep 2
done

# Final memory reading
FINAL_MEM=$(_olr_memory_mb)

# ---- Stage 5: Compare outputs ----
echo ""
echo "--- Stage 5: Compare LogMiner vs OLR Debezium output ---"

LM_FILE="$SCRIPT_DIR/output/logminer.jsonl"
OLR_FILE="$SCRIPT_DIR/output/olr.jsonl"

COMPARE_RESULT=0
if [[ ! -s "$LM_FILE" ]]; then
    echo "ERROR: LogMiner output is empty: $LM_FILE" >&2
    COMPARE_RESULT=1
elif [[ ! -s "$OLR_FILE" ]]; then
    echo "ERROR: OLR output is empty: $OLR_FILE" >&2
    COMPARE_RESULT=1
elif python3 "$DBZ_TWIN_DIR/compare-debezium.py" "$LM_FILE" "$OLR_FILE"; then
    echo "  Data accuracy: PASS"
else
    echo "  Data accuracy: FAIL"
    COMPARE_RESULT=1
fi

# ---- Stage 6: Memory report ----
echo ""
echo "--- Stage 6: Memory report ---"
echo ""

# Print header + sampled rows from CSV
echo "  Round | Elapsed | Memory (MB) | Ops (round) | Total Ops"
echo "  ------|---------|-------------|-------------|----------"
LINE_COUNT=$(wc -l < "$MEMORY_LOG")
# Show ~20 evenly spaced rows
STEP=$(( (LINE_COUNT - 1) / 20 ))
[[ $STEP -lt 1 ]] && STEP=1
ROW=0
while IFS=, read -r r e m rops tops; do
    [[ "$r" == "round" ]] && continue
    ROW=$(( ROW + 1 ))
    if [[ "$r" == "0" || "$r" == "$ROUND" || $(( ROW % STEP )) == 0 ]]; then
        printf "  %5s | %6ss | %10s | %10s | %s\n" "$r" "$e" "$m" "$rops" "$tops"
    fi
done < "$MEMORY_LOG"

echo ""
echo "  Initial memory: ${INIT_MEM} MB"
echo "  Final memory:   ${FINAL_MEM} MB"

# Get OLR's self-reported memory HWM from logs
OLR_HWM=$(ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman logs $OLR_CONTAINER 2>&1 | grep 'Memory HWM' | tail -1" 2>/dev/null || echo "N/A")
if [[ -n "$OLR_HWM" && "$OLR_HWM" != "N/A" ]]; then
    echo "  OLR self-reported: $OLR_HWM"
fi

# Memory trend analysis
if [[ "$INIT_MEM" != "N/A" && "$FINAL_MEM" != "N/A" ]]; then
    GROWTH=$(( FINAL_MEM - INIT_MEM ))
    if [[ $GROWTH -gt 200 ]]; then
        echo ""
        echo "  WARNING: Memory grew by ${GROWTH} MB — possible leak"
    elif [[ $GROWTH -gt 50 ]]; then
        echo ""
        echo "  NOTE: Memory grew by ${GROWTH} MB — moderate growth"
    else
        echo ""
        echo "  Memory stable (delta: ${GROWTH} MB)"
    fi
fi

# ---- Summary ----
echo ""
echo "========================================"
echo "  Soak Test Summary"
echo "========================================"
echo "  Rounds:     $ROUND"
echo "  Total ops:  $TOTAL_OPS"
echo "  Duration:   $(( $(date +%s) - SOAK_START ))s"
echo "  Memory:     ${INIT_MEM} MB -> ${FINAL_MEM} MB"

if [[ $COMPARE_RESULT -eq 0 ]]; then
    echo "  Accuracy:   PASS"
    echo ""
    echo "=== PASS: Soak test completed ==="
else
    echo "  Accuracy:   FAIL"
    echo ""
    echo "=== FAIL: Soak test data accuracy mismatch ==="
    echo "  LogMiner output: $LM_FILE"
    echo "  OLR output:      $OLR_FILE"
fi

# Copy memory log to a persistent location
PERSIST_LOG="/tmp/soak-test-memory-$(date +%Y%m%d-%H%M%S).csv"
cp "$MEMORY_LOG" "$PERSIST_LOG"
echo ""
echo "  Memory CSV saved to: $PERSIST_LOG"

exit $COMPARE_RESULT
