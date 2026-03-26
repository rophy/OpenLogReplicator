#!/usr/bin/env bash
# checkpoint-restart-test.sh — Single-instance checkpoint/restart test.
#
# Same logic as the RAC version but against local Docker Oracle XE 21c.
# Tests whether Bug 1 (duplicate SYS.TAB$) and Bug 2 (heap-use-after-free)
# are RAC-specific or also present in single-instance mode.
#
# Usage: ./checkpoint-restart-test.sh [kill-count]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR"

KILL_COUNT="${1:-3}"
RECEIVER_URL="http://localhost:8080"
POLL_TIMEOUT=180
OLR_CONTAINER="dbz-olr"
ORACLE_CONTAINER="dbz-oracle"
ORACLE_PORT="${ORACLE_PORT:-1522}"
DB_CONN="olr_test/olr_test@//localhost:1521/XEPDB1"
CHECKPOINT_VOL="debezium_olr-checkpoint"
DDL_BETWEEN_RESTARTS="${DDL_BETWEEN_RESTARTS:-true}"

WORK_DIR=$(mktemp -d /tmp/chkpt_single_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- Config with short checkpoint interval ----
cat > "$WORK_DIR/olr-config.json" << 'EOF'
{
  "version": "1.9.0",
  "log-level": 4,
  "state": {
    "type": "disk",
    "path": "/olr-data/checkpoint",
    "interval-s": 10,
    "interval-mb": 1
  },
  "memory": {
    "min-mb": 64,
    "max-mb": 256
  },
  "source": [
    {
      "alias": "SOURCE",
      "name": "XE",
      "reader": {
        "type": "online",
        "user": "c##dbzuser",
        "password": "dbz",
        "server": "//oracle:1521/XEPDB1"
      },
      "format": {
        "type": "debezium",
        "scn-type": 1,
        "timestamp-type": 1,
        "user-type": 0,
        "redo-thread": 0
      },
      "filter": {
        "table": [
          {"owner": "OLR_TEST", "table": ".*"}
        ]
      }
    }
  ],
  "target": [
    {
      "alias": "DEBEZIUM",
      "source": "SOURCE",
      "writer": {
        "type": "network",
        "uri": "0.0.0.0:5000"
      }
    }
  ]
}
EOF

_sqlplus() {
    docker exec "$ORACLE_CONTAINER" sqlplus -S "$1" @"$2"
}

_exec_sysdba() {
    local sql_file="$1"
    docker cp "$sql_file" "$ORACLE_CONTAINER:/tmp/$(basename "$sql_file")"
    docker exec "$ORACLE_CONTAINER" bash -c "export ORACLE_SID=XE; sqlplus -S / as sysdba @/tmp/$(basename "$sql_file")"
}

_exec_user() {
    local sql_file="$1"
    docker cp "$sql_file" "$ORACLE_CONTAINER:/tmp/$(basename "$sql_file")"
    local output
    output=$(docker exec "$ORACLE_CONTAINER" bash -c "sqlplus -S '$DB_CONN' @/tmp/$(basename "$sql_file")")
    if echo "$output" | grep -q "^ORA-\|^SP2-"; then
        echo "ERROR: SQL failed:" >&2
        echo "$output" >&2
        return 1
    fi
    echo "$output"
}

_log_switch() {
    cat > "$WORK_DIR/log_switch.sql" <<'SQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH LOGFILE;
BEGIN DBMS_SESSION.SLEEP(2); END;
/
EXIT
SQL
    _exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null
}

_read_checkpoint_scn() {
    if ! docker volume inspect "$CHECKPOINT_VOL" > /dev/null 2>&1; then
        echo "0"
        return
    fi
    docker run --rm -v "${CHECKPOINT_VOL}:/data" alpine sh -c \
        'cat /data/XE-chkpt.json 2>/dev/null' 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('scn',0))" 2>/dev/null || echo "0"
}

_read_checkpoint() {
    docker run --rm -v "${CHECKPOINT_VOL}:/data" alpine sh -c \
        'cat /data/XE-chkpt.json 2>/dev/null' 2>/dev/null | \
        python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'scn={d[\"scn\"]}, idx={d.get(\"idx\",\"?\")}')
except: print('no checkpoint')
" 2>/dev/null || echo "no checkpoint"
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
    echo "  WARNING: No checkpoint after 30s"
    return 1
}

_launch_olr() {
    echo "  Launching OLR..."
    docker rm -f "$OLR_CONTAINER" > /dev/null 2>&1 || true
    # Get Oracle container's network
    local net
    net=$(docker inspect "$ORACLE_CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)

    docker run -d --name "$OLR_CONTAINER" \
        --network "$net" \
        --network-alias olr \
        --group-add 54321 \
        --entrypoint bash \
        -v "$WORK_DIR/olr-config.json:/config/olr-config.json:ro" \
        -v "${CHECKPOINT_VOL}:/olr-data/checkpoint" \
        -v "debezium_oracle-data:/opt/oracle/oradata:ro" \
        -w /olr-data \
        olr-dev:latest \
        -c "mkdir -p /olr-data/checkpoint && /opt/OpenLogReplicator/OpenLogReplicator -r -f /config/olr-config.json" \
        > /dev/null
    echo "  OLR container started"
}

_wait_olr_ready() {
    echo "  Waiting for OLR to start processing..."
    for i in $(seq 1 90); do
        local state
        state=$(docker inspect "$OLR_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
        if [[ "$state" == "exited" ]]; then
            echo "  ERROR: OLR exited unexpectedly" >&2
            docker logs "$OLR_CONTAINER" 2>&1 | tail -20 >&2
            return 1
        fi
        if docker logs "$OLR_CONTAINER" 2>&1 | grep -q "processing redo log"; then
            echo "  OLR: ready (${i}x2s)"
            return 0
        fi
        sleep 2
    done
    echo "  ERROR: OLR did not become ready in 180s" >&2
    docker logs "$OLR_CONTAINER" 2>&1 | tail -20 >&2
    return 1
}

_kill_olr() {
    local cycle="${1:-unknown}"
    echo "  Killing OLR (SIGKILL)..."
    # Preserve logs before removing container
    docker logs "$OLR_CONTAINER" > "$WORK_DIR/olr-cycle-${cycle}.log" 2>&1 || true
    docker kill "$OLR_CONTAINER" > /dev/null 2>&1 || true
    docker rm -f "$OLR_CONTAINER" > /dev/null 2>&1 || true
    echo "  Last checkpoint: $(_read_checkpoint)"
}

echo "=== Single-Instance Checkpoint/Restart Test ==="
echo "  Kill cycles: $KILL_COUNT"
echo ""

# ---- Stage 1: Verify services ----
echo "--- Stage 1: Verify services ---"

if ! docker ps --format '{{.Names}}' | grep -q "^${ORACLE_CONTAINER}$"; then
    echo "ERROR: Oracle container not running. Run: cd tests/dbz-twin && docker compose up -d oracle" >&2
    exit 1
fi
echo "  Oracle: OK"

if ! curl -sf "$RECEIVER_URL/health" > /dev/null 2>&1; then
    echo "ERROR: Receiver not responding. Run: cd tests/dbz-twin && docker compose up -d receiver" >&2
    exit 1
fi
echo "  Receiver: OK"

# ---- Stage 2: Setup ----
echo ""
echo "--- Stage 2: Setup ---"

cat > "$WORK_DIR/setup.sql" <<'SQL'
SET FEEDBACK OFF
SET SERVEROUTPUT ON

BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.CHKPT_TEST PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/

CREATE TABLE olr_test.CHKPT_TEST (
  id        NUMBER PRIMARY KEY,
  val       VARCHAR2(200),
  phase     VARCHAR2(50),
  created   TIMESTAMP DEFAULT SYSTIMESTAMP
);
ALTER TABLE olr_test.CHKPT_TEST ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

EXIT
SQL
_exec_user "$WORK_DIR/setup.sql"
_log_switch

# Clean checkpoint volume and fix permissions
docker rm -f "$OLR_CONTAINER" > /dev/null 2>&1 || true
docker volume rm -f "$CHECKPOINT_VOL" > /dev/null 2>&1 || true
docker volume create "$CHECKPOINT_VOL" > /dev/null
# OLR runs as uid=1000, gid=54322 — set volume ownership
docker run --rm -v "${CHECKPOINT_VOL}:/data" alpine sh -c "chown 1000:54322 /data && chmod 775 /data"
echo "  Checkpoint volume cleared (permissions set for uid=1000)"

# Restart Debezium connectors
echo "  Restarting Debezium connectors..."
cd "$SCRIPT_DIR"
for svc in dbz-logminer dbz-olr; do
    docker compose rm -sf "$svc" > /dev/null 2>&1 || true
done
docker volume rm -f debezium_dbz-logminer-data debezium_dbz-olr-data > /dev/null 2>&1 || true
docker compose up -d dbz-logminer > /dev/null 2>&1
cd - > /dev/null

for i in $(seq 1 60); do
    if docker logs dbz-logminer 2>&1 | tail -20 | grep -q "Starting streaming"; then
        echo "  LogMiner: streaming"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "ERROR: LogMiner did not start" >&2
        docker logs dbz-logminer 2>&1 | tail -10 >&2
        exit 1
    fi
    sleep 2
done

curl -sf -X POST "$RECEIVER_URL/reset" > /dev/null

# ---- Stage 3: Kill/restart cycles ----
echo ""
echo "--- Stage 3: Kill/restart cycles ---"

BATCH=50
NEXT_ID=1000
CHECKPOINT_VERIFIED=0

# Launch OLR, then start Debezium adapter (which connects to OLR and triggers processing)
_launch_olr
sleep 2
cd "$SCRIPT_DIR"
docker compose up -d --no-deps dbz-olr > /dev/null 2>&1
cd - > /dev/null
_wait_olr_ready

for cycle in $(seq 1 "$KILL_COUNT"); do
    echo ""
    echo "  === Cycle $cycle / $KILL_COUNT ==="

    # Phase A: DML while running
    cat > "$WORK_DIR/dml.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  FOR i IN ${NEXT_ID}..$(( NEXT_ID + BATCH - 1 )) LOOP
    INSERT INTO olr_test.CHKPT_TEST (id, val, phase)
    VALUES (i, 'c${cycle}_running_' || i, 'c${cycle}_running');
  END LOOP;
  COMMIT;
END;
/
EXIT
SQL
    _exec_user "$WORK_DIR/dml.sql" > /dev/null
    _log_switch
    echo "  c${cycle}_running: inserted $BATCH rows (IDs ${NEXT_ID}-$(( NEXT_ID + BATCH - 1 )))"
    NEXT_ID=$(( NEXT_ID + BATCH ))

    # Wait for checkpoint
    _wait_for_checkpoint || true
    PRE_KILL_SCN=$(_read_checkpoint_scn)

    # Kill
    _kill_olr "$cycle"

    # DDL while OLR is down (triggers Bug 1: schema checkpoint accumulation)
    if [[ "$DDL_BETWEEN_RESTARTS" == "true" ]]; then
        cat > "$WORK_DIR/ddl.sql" <<SQL
SET FEEDBACK OFF
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.CHKPT_AUX PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.CHKPT_AUX (id NUMBER PRIMARY KEY, val VARCHAR2(100));
ALTER TABLE olr_test.CHKPT_AUX ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
EXIT
SQL
        _exec_user "$WORK_DIR/ddl.sql" > /dev/null
        _log_switch
        echo "  c${cycle}: DDL (DROP+CREATE CHKPT_AUX)"
    fi

    # Phase B: DML while down
    cat > "$WORK_DIR/dml.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  FOR i IN ${NEXT_ID}..$(( NEXT_ID + BATCH - 1 )) LOOP
    INSERT INTO olr_test.CHKPT_TEST (id, val, phase)
    VALUES (i, 'c${cycle}_offline_' || i, 'c${cycle}_offline');
  END LOOP;
  COMMIT;
END;
/
EXIT
SQL
    _exec_user "$WORK_DIR/dml.sql" > /dev/null
    _log_switch
    echo "  c${cycle}_offline: inserted $BATCH rows (IDs ${NEXT_ID}-$(( NEXT_ID + BATCH - 1 )))"
    NEXT_ID=$(( NEXT_ID + BATCH ))

    # Restart — adapter auto-reconnects (restart: unless-stopped)
    _launch_olr
    sleep 2
    _wait_olr_ready

    # Verify checkpoint resume
    POST_RESTART_SCN=$(_read_checkpoint_scn)
    if [[ "$PRE_KILL_SCN" != "0" && "$POST_RESTART_SCN" != "0" ]]; then
        echo "  Checkpoint resume: pre-kill=$PRE_KILL_SCN, post-restart=$POST_RESTART_SCN"
        if [[ "$POST_RESTART_SCN" -ge "$PRE_KILL_SCN" ]]; then
            echo "  PASS: resumed from checkpoint"
            CHECKPOINT_VERIFIED=$(( CHECKPOINT_VERIFIED + 1 ))
        fi
    fi

    _wait_for_checkpoint || true
    sleep 5

    # Phase C: DML after restart
    cat > "$WORK_DIR/dml.sql" <<SQL
SET FEEDBACK OFF
BEGIN
  FOR i IN ${NEXT_ID}..$(( NEXT_ID + BATCH - 1 )) LOOP
    INSERT INTO olr_test.CHKPT_TEST (id, val, phase)
    VALUES (i, 'c${cycle}_resumed_' || i, 'c${cycle}_resumed');
  END LOOP;
  COMMIT;
END;
/
EXIT
SQL
    _exec_user "$WORK_DIR/dml.sql" > /dev/null
    _log_switch
    echo "  c${cycle}_resumed: inserted $BATCH rows (IDs ${NEXT_ID}-$(( NEXT_ID + BATCH - 1 )))"
    NEXT_ID=$(( NEXT_ID + BATCH ))
done

TOTAL_ROWS=$(( KILL_COUNT * 3 * BATCH ))
echo ""
echo "  Total: $TOTAL_ROWS rows"

# ---- Stage 4: Sentinel ----
echo ""
echo "--- Stage 4: Sentinel + wait ---"
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

START_TIME=$(date +%s)
SENTINEL_OK=true
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $POLL_TIMEOUT ]]; then
        echo ""
        echo "ERROR: Timeout" >&2
        SENTINEL_OK=false
        break
    fi
    STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
    LM_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_sentinel',False))" 2>/dev/null || echo "False")
    OLR_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_sentinel',False))" 2>/dev/null || echo "False")
    LM_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_count',0))" 2>/dev/null || echo "0")
    OLR_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_count',0))" 2>/dev/null || echo "0")

    printf "\r  [%3ds] LM: %s (sentinel: %s) | OLR: %s (sentinel: %s)   " \
        "$ELAPSED" "$LM_COUNT" "$LM_SENTINEL" "$OLR_COUNT" "$OLR_SENTINEL"

    if [[ "$LM_SENTINEL" == "True" && "$OLR_SENTINEL" == "True" ]]; then
        echo ""
        echo "  Done"
        break
    fi
    sleep 2
done

# ---- Stage 5: Compare ----
echo ""
echo "--- Stage 5: Compare ---"
LM_FILE="$SCRIPT_DIR/output/logminer.jsonl"
OLR_FILE="$SCRIPT_DIR/output/olr.jsonl"

COMPARE_RESULT=0
if [[ "$SENTINEL_OK" != "true" ]]; then
    echo "  FAIL: Sentinel timeout"
    COMPARE_RESULT=1
elif python3 "$SCRIPTS_DIR/compare-debezium.py" "$LM_FILE" "$OLR_FILE"; then
    echo "  Data accuracy: PASS"
else
    echo "  Data accuracy: FAIL"
    COMPARE_RESULT=1
fi

# ---- Check for ASAN errors and OLR errors ----
echo ""
echo "--- Stage 6: Error checks ---"
ASAN_RESULT=0
OLR_ERROR_RESULT=0
# Save final container logs and combine with per-cycle logs
docker logs "$OLR_CONTAINER" > "$WORK_DIR/olr-cycle-final.log" 2>&1 || true
cat "$WORK_DIR"/olr-cycle-*.log > "$WORK_DIR/olr-all.log" 2>/dev/null || true

if grep -q "AddressSanitizer\|ABORTING" "$WORK_DIR/olr-all.log"; then
    echo "  FAIL: ASAN errors detected"
    grep -A5 "AddressSanitizer" "$WORK_DIR/olr-all.log" | head -10
    ASAN_RESULT=1
else
    echo "  PASS: No ASAN errors"
fi

if grep -q "duplicate\|ERROR 50022" "$WORK_DIR/olr-all.log"; then
    echo "  FAIL: OLR duplicate/schema errors detected"
    grep "duplicate\|ERROR 50022" "$WORK_DIR/olr-all.log" | head -5
    OLR_ERROR_RESULT=1
else
    echo "  PASS: No OLR duplicate/schema errors"
fi

# ---- Summary ----
echo ""
echo "========================================"
echo "  Single-Instance Checkpoint/Restart"
echo "========================================"
echo "  Cycles: $KILL_COUNT, Rows: $TOTAL_ROWS"
CHKPT_RESULT=0
if [[ $CHECKPOINT_VERIFIED -lt 1 ]]; then
    CHKPT_RESULT=1
fi

echo "  Checkpoint verified: $CHECKPOINT_VERIFIED / $KILL_COUNT"
echo "  Accuracy:   $([ $COMPARE_RESULT -eq 0 ] && echo PASS || echo FAIL)"
echo "  ASAN:       $([ $ASAN_RESULT -eq 0 ] && echo PASS || echo FAIL)"
echo "  OLR errors: $([ $OLR_ERROR_RESULT -eq 0 ] && echo PASS || echo FAIL)"
echo "  Checkpoint: $([ $CHKPT_RESULT -eq 0 ] && echo PASS || echo FAIL)"
echo "  DDL between restarts: $DDL_BETWEEN_RESTARTS"

if [[ $COMPARE_RESULT -eq 0 && $ASAN_RESULT -eq 0 && $OLR_ERROR_RESULT -eq 0 && $CHKPT_RESULT -eq 0 ]]; then
    echo ""
    echo "=== PASS ==="
else
    echo ""
    echo "=== FAIL ==="
fi

exit $(( COMPARE_RESULT + ASAN_RESULT + OLR_ERROR_RESULT + CHKPT_RESULT ))
