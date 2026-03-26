#!/usr/bin/env bash
# run.sh — Run Debezium twin-test for a scenario against RAC.
#
# Runs the same SQL scenario through two Debezium Server instances:
# one with LogMiner adapter, one with OLR adapter. Compares the CDC
# outputs to verify OLR compatibility with RAC.
#
# Usage: ./run.sh <scenario-name>
# Example: ./run.sh basic-crud
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

SCENARIO="${1:?Usage: $0 <scenario-name>}"

# ---- RAC configuration ----
VM_HOST="${VM_HOST:-192.168.122.248}"
VM_KEY="${VM_KEY:-$PROJECT_ROOT/oracle-rac/assets/vm-key}"
VM_USER="${VM_USER:-root}"
OLR_IMAGE="${OLR_IMAGE:-docker.io/library/olr-dev:latest}"
RAC_NODE1="${RAC_NODE1:-racnodep1}"
RAC_NODE2="${RAC_NODE2:-racnodep2}"
ORACLE_SID1="${ORACLE_SID1:-ORCLCDB1}"
ORACLE_SID2="${ORACLE_SID2:-ORCLCDB2}"
DB_CONN1="${DB_CONN1:-olr_test/olr_test@//racnodep1:1521/ORCLPDB}"
DB_CONN2="${DB_CONN2:-olr_test/olr_test@//racnodep2:1521/ORCLPDB}"

OLR_CONTAINER="olr-debezium"
RECEIVER_URL="${RECEIVER_URL:-http://localhost:8080}"
POLL_TIMEOUT="${POLL_TIMEOUT:-120}"

_SSH_OPTS="-i $VM_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ---- SSH helpers (same pattern as rac.sh driver) ----
_vm_sqlplus() {
    local node="$1" sid="$2" conn="$3" sql_file="$4"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $node su - oracle -c 'export ORACLE_SID=$sid; sqlplus -S \"$conn\" @$sql_file'"
}

_vm_copy_in() {
    local local_path="$1" container_path="$2" node="$3"
    local staging="/tmp/_dbz_staging_$$"
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

# ---- Helper: parse and run .rac.sql blocks ----
# Parse .rac.sql into block files. Only parses; does not execute.
_parse_rac_blocks() {
    local sql_file="$1" work="$2"
    local block_idx=0 current_type="" current_file=""

    rm -f "$work"/block_*_*.sql

    while IFS= read -r line; do
        if [[ "$line" =~ ^--[[:space:]]*@SETUP ]]; then
            current_type="setup"
            current_file="$work/block_$(printf '%03d' $block_idx)_setup.sql"
            block_idx=$((block_idx + 1))
            cat > "$current_file" <<'H'
SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF
H
            continue
        elif [[ "$line" =~ ^--[[:space:]]*@NODE1 ]]; then
            current_type="node1"
            current_file="$work/block_$(printf '%03d' $block_idx)_node1.sql"
            block_idx=$((block_idx + 1))
            cat > "$current_file" <<'H'
SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF
H
            continue
        elif [[ "$line" =~ ^--[[:space:]]*@NODE2 ]]; then
            current_type="node2"
            current_file="$work/block_$(printf '%03d' $block_idx)_node2.sql"
            block_idx=$((block_idx + 1))
            cat > "$current_file" <<'H'
SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF
H
            continue
        fi
        [[ -n "$current_file" ]] && echo "$line" >> "$current_file"
    done < "$sql_file"

    for f in "$work"/block_*_*.sql; do
        [[ -f "$f" ]] || continue
        echo "" >> "$f"
        echo "EXIT" >> "$f"
    done
}

# Run parsed blocks, with optional filter.
# Usage: _run_rac_blocks <work_dir> [filter]
# filter: "all" (default), "setup" (only setup blocks), "dml" (only node1/node2 blocks)
_run_rac_blocks() {
    local work="$1"
    local filter="${2:-all}"

    for block_file in "$work"/block_*_*.sql; do
        [[ -f "$block_file" ]] || continue
        local block_name block_type
        block_name=$(basename "$block_file" .sql)
        block_type="${block_name##*_}"

        case "$filter" in
            setup) [[ "$block_type" != "setup" ]] && continue ;;
            dml)   [[ "$block_type" == "setup" ]] && continue ;;
        esac

        case "$block_type" in
            setup) _exec_user "$block_file" "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1" ;;
            node1) _exec_user "$block_file" "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1" ;;
            node2) _exec_user "$block_file" "$RAC_NODE2" "$ORACLE_SID2" "$DB_CONN2" ;;
        esac
    done
}

# ---- Find scenario SQL ----
SCENARIO_SQL="$TESTS_DIR/sql/inputs/${SCENARIO}.sql"
if [[ ! -f "$SCENARIO_SQL" ]]; then
    SCENARIO_SQL="$TESTS_DIR/sql/inputs/${SCENARIO}.rac.sql"
fi
if [[ ! -f "$SCENARIO_SQL" ]]; then
    echo "ERROR: Scenario file not found: $SCENARIO" >&2
    exit 1
fi

# Skip scenarios tagged with anything other than 'rac'
SCENARIO_TAGS=$(grep '^-- @TAG ' "$SCENARIO_SQL" 2>/dev/null | sed 's/^-- @TAG //' || true)
NON_RAC_TAGS=$(echo "$SCENARIO_TAGS" | tr ' ' '\n' | grep -v '^rac$' | grep -v '^$' || true)
if [[ -n "$NON_RAC_TAGS" ]]; then
    echo "SKIP: $SCENARIO has non-RAC tags ($NON_RAC_TAGS)"
    exit 0
fi

# Skip DDL scenarios
if grep -q '^-- @DDL' "$SCENARIO_SQL" 2>/dev/null; then
    echo "SKIP: $SCENARIO uses @DDL — not compatible with Debezium twin-test"
    exit 0
fi

IS_RAC_SQL=false
[[ "$SCENARIO_SQL" == *.rac.sql ]] && IS_RAC_SQL=true

echo "=== Debezium RAC twin-test: $SCENARIO ==="

# ---- Stage 1: Verify services ----
echo ""
echo "--- Stage 1: Verify services ---"

# Check receiver
if ! curl -sf "$RECEIVER_URL/health" > /dev/null 2>&1; then
    echo "ERROR: Receiver not responding at $RECEIVER_URL" >&2
    echo "Run: make -C tests/environments/rac/debezium up" >&2
    exit 1
fi
echo "  Receiver: OK"

# Check RAC
if ! ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec $RAC_NODE1 su - oracle -c 'export ORACLE_SID=$ORACLE_SID1; printf \"SELECT 1 FROM dual;\nEXIT;\n\" | sqlplus -S / as sysdba'" 2>/dev/null | grep -q "1"; then
    echo "ERROR: RAC Oracle not reachable on $VM_HOST" >&2
    exit 1
fi
echo "  Oracle RAC: OK"

# Check Debezium LogMiner container (OLR adapter is restarted per-scenario in Stage 2)
if ! docker ps --format '{{.Names}}' | grep -q "^dbz-logminer$"; then
    echo "ERROR: Container dbz-logminer not running" >&2
    exit 1
fi
echo "  Debezium: OK"

# ---- Stage 2: Run DDL + restart connectors ----
echo ""
echo "--- Stage 2: Run DDL and restart connectors ---"

# Run the full SQL to create tables (on node 1 for regular .sql; parsed blocks for .rac.sql)
WORK_DIR=$(mktemp -d /tmp/dbz_rac_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

if $IS_RAC_SQL; then
    # Parse .rac.sql into blocks; run SETUP only (tables + seed data)
    _parse_rac_blocks "$SCENARIO_SQL" "$WORK_DIR"
    _run_rac_blocks "$WORK_DIR" setup
else
    # Extract only the DDL portion (up to and including the FIXTURE_SCN_START block).
    # Running the full SQL would cause Stage 2 DML events to leak into the
    # Stage 3 capture window when OLR hasn't finished processing them before
    # the receiver reset.
    cat > "$WORK_DIR/ddl.sql" <<HEADER
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
HEADER
    python3 -c "
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
# Find the / terminator after FIXTURE_SCN_START block
scn_start = None
for i, l in enumerate(lines):
    if 'FIXTURE_SCN_START' in l and 'DBMS_OUTPUT' in l:
        scn_start = i
        break
if scn_start is None:
    # No SCN markers — include everything (e.g. simple DDL-only scripts)
    for line in lines:
        sys.stdout.write(line)
else:
    # Include everything up to and including the / after SCN_START block
    end = scn_start
    for i in range(scn_start, len(lines)):
        if lines[i].strip() == '/':
            end = i + 1
            break
    for line in lines[:end]:
        sys.stdout.write(line)
" "$SCENARIO_SQL" >> "$WORK_DIR/ddl.sql"
    echo "" >> "$WORK_DIR/ddl.sql"
    echo "EXIT" >> "$WORK_DIR/ddl.sql"
    _exec_user "$WORK_DIR/ddl.sql" > /dev/null 2>&1
fi
echo "  DDL executed (tables created)"

# Force log switch on all instances
cat > "$WORK_DIR/log_switch.sql" <<'SQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH ALL LOGFILE;
BEGIN DBMS_SESSION.SLEEP(2); END;
/
EXIT
SQL
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

# Stop existing OLR on VM
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman stop -t5 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"

# Deploy OLR config to VM
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "mkdir -p /root/olr-debezium/config /root/olr-debezium/checkpoint"
scp $_SSH_OPTS "$SCRIPT_DIR/config/olr-config.json" "${VM_USER}@${VM_HOST}:/root/olr-debezium/config/"

# Clean checkpoint and fix ownership
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "rm -rf /root/olr-debezium/checkpoint/* && chown -R 1000:54335 /root/olr-debezium/checkpoint"

# Start OLR on VM with network writer
echo "  Starting OLR on RAC VM..."
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman run -d --name $OLR_CONTAINER \
    --user 1000:54335 \
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

# Wait for OLR to start processing redo logs
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

# ---- Stage 3: Reset receiver + run DML ----
echo ""
echo "--- Stage 3: Run scenario DML ---"
curl -sf -X POST "$RECEIVER_URL/reset" > /dev/null
echo "  Receiver state cleared"

# Extract and run only the DML portion of the scenario SQL.
# On RAC, re-running DDL (DROP+CREATE TABLE) during OLR streaming causes
# OLR's DDL tracking to interfere with DML event capture. We avoid this by
# running only the DML lines (between FIXTURE_SCN_START and FIXTURE_SCN_END).
if $IS_RAC_SQL; then
    # Run only NODE1/NODE2 blocks (SETUP already ran in Stage 2)
    _run_rac_blocks "$WORK_DIR" dml
else
    cat > "$WORK_DIR/dml.sql" <<'HEADER'
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
HEADER
    python3 -c "
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
start_idx = end_idx = None
for i, l in enumerate(lines):
    if 'FIXTURE_SCN_START' in l and 'DBMS_OUTPUT' in l:
        start_idx = i
    if 'FIXTURE_SCN_END' in l and 'DBMS_OUTPUT' in l:
        end_idx = i
if start_idx is None or end_idx is None:
    sys.exit(1)
for i in range(start_idx, len(lines)):
    if lines[i].strip() == '/':
        start_idx = i + 1; break
for i in range(end_idx, -1, -1):
    if lines[i].strip() == 'DECLARE':
        end_idx = i; break
for line in lines[start_idx:end_idx]:
    sys.stdout.write(line)
" "$SCENARIO_SQL" >> "$WORK_DIR/dml.sql"
    echo "" >> "$WORK_DIR/dml.sql"
    echo "EXIT" >> "$WORK_DIR/dml.sql"
    _exec_user "$WORK_DIR/dml.sql" > /dev/null 2>&1
fi
echo "  Scenario SQL executed"

# Force log switch
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null
echo "  Log switch forced"

# ---- Stage 4: Insert sentinel ----
echo ""
echo "--- Stage 4: Insert sentinel ---"
cat > "$WORK_DIR/sentinel.sql" <<SQL
DELETE FROM DEBEZIUM_SENTINEL;
INSERT INTO DEBEZIUM_SENTINEL VALUES (1, '$SCENARIO');
COMMIT;
EXIT;
SQL
_exec_user "$WORK_DIR/sentinel.sql" > /dev/null
echo "  Sentinel inserted"

# Force another log switch
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

# ---- Stage 5: Wait for completion ----
echo ""
echo "--- Stage 5: Waiting for both connectors to process events ---"

START_TIME=$(date +%s)
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $POLL_TIMEOUT ]]; then
        echo ""
        echo "ERROR: Timeout after ${POLL_TIMEOUT}s waiting for events" >&2
        STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
        echo "  Final status: $STATUS" >&2
        exit 1
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

# ---- Stage 6: Compare outputs ----
echo ""
echo "--- Stage 6: Compare LogMiner vs OLR Debezium output ---"

LM_FILE="$SCRIPT_DIR/output/logminer.jsonl"
OLR_FILE="$SCRIPT_DIR/output/olr.jsonl"

if [[ ! -s "$LM_FILE" ]]; then
    echo "ERROR: LogMiner output is empty: $LM_FILE" >&2
    exit 1
fi
if [[ ! -s "$OLR_FILE" ]]; then
    echo "ERROR: OLR output is empty: $OLR_FILE" >&2
    exit 1
fi

if python3 "$DBZ_TWIN_DIR/compare-debezium.py" "$LM_FILE" "$OLR_FILE"; then
    echo ""
    echo "=== PASS: Debezium RAC twin-test '$SCENARIO' ==="
else
    echo ""
    echo "=== FAIL: Debezium RAC twin-test '$SCENARIO' ==="
    echo "  LogMiner output: $LM_FILE"
    echo "  OLR output:      $OLR_FILE"
    exit 1
fi
