#!/usr/bin/env bash
# Driver: rac
# Oracle via SSH to RAC VM + podman exec, OLR via docker run.
#
# Handles .rac.sql files with block-based SQL:
#   -- @SETUP  — Table creation, supplemental logging, SCN capture (node 1)
#   -- @NODE1  — DML executed on node 1
#   -- @NODE2  — DML executed on node 2
#
# Environment variables:
#   VM_HOST       — Oracle VM IP (default: 192.168.122.248)
#   VM_KEY        — SSH key path (default: oracle-rac/assets/vm-key)
#   VM_USER       — SSH user (default: root)
#   OLR_IMAGE     — Docker image for OLR (default: rophy/openlogreplicator:latest)
#   RAC_NODE1     — Container name for node 1 (default: racnodep1)
#   RAC_NODE2     — Container name for node 2 (default: racnodep2)
#   ORACLE_SID1   — Oracle SID for node 1 (default: ORCLCDB1)
#   ORACLE_SID2   — Oracle SID for node 2 (default: ORCLCDB2)
#   DB_CONN1      — PDB connect string via node 1 (default: olr_test/olr_test@//racnodep1:1521/ORCLPDB)
#   DB_CONN2      — PDB connect string via node 2 (default: olr_test/olr_test@//racnodep2:1521/ORCLPDB)

# ---- RAC-specific variables (set BEFORE sourcing base.sh) ----
SWITCH_LOGFILE_SQL="ALTER SYSTEM SWITCH ALL LOGFILE"
ARCHIVE_LOG_VIEW='gv$archived_log'
ARCHIVE_RETRY_ATTEMPTS=5
ARCHIVE_MIN_THREADS=2
FIXTURE_SUFFIX=""

# Source base driver (stage functions + primitive stubs)
PDB_NAME="${PDB_NAME:-ORCLPDB}"

source "$SCRIPT_DIR/drivers/base.sh"

# ---- RAC configuration ----
VM_HOST="${VM_HOST:-192.168.122.248}"
VM_KEY="${VM_KEY:-$PROJECT_ROOT/oracle-rac/assets/vm-key}"
VM_USER="${VM_USER:-root}"
OLR_IMAGE="${OLR_IMAGE:-rophy/openlogreplicator:latest}"
RAC_NODE1="${RAC_NODE1:-racnodep1}"
RAC_NODE2="${RAC_NODE2:-racnodep2}"
ORACLE_SID1="${ORACLE_SID1:-ORCLCDB1}"
ORACLE_SID2="${ORACLE_SID2:-ORCLCDB2}"
DB_CONN1="${DB_CONN1:-olr_test/olr_test@//racnodep1:1521/ORCLPDB}"
DB_CONN2="${DB_CONN2:-olr_test/olr_test@//racnodep2:1521/ORCLPDB}"

_SSH_OPTS="-i $VM_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Unique VM staging file per scenario to avoid parallel conflicts
_VM_STAGING="/tmp/_fixture_${SCENARIO}_$$"

# ---- Internal helpers ----

# Run sqlplus on a specific node
_vm_sqlplus() {
    local node="$1"
    local sid="$2"
    local conn="$3"
    local sql_file="$4"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $node su - oracle -c 'export ORACLE_SID=$sid; sqlplus -S \"$conn\" @$sql_file'"
}

# Copy a local file into a RAC container
_vm_copy_in() {
    local local_path="$1"
    local container_path="$2"
    local node="$3"
    scp $_SSH_OPTS "$local_path" "${VM_USER}@${VM_HOST}:${_VM_STAGING}"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman cp ${_VM_STAGING} ${node}:${container_path}; rm -f ${_VM_STAGING}"
}

# Copy a file from a RAC container to local
_vm_copy_out() {
    local node="$1"
    local container_path="$2"
    local local_path="$3"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman cp ${node}:${container_path} ${_VM_STAGING}"
    scp $_SSH_OPTS "${VM_USER}@${VM_HOST}:${_VM_STAGING}" "$local_path"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "rm -f ${_VM_STAGING}"
}

# ---- Primitives ----

_exec_sysdba() {
    local sql_file="$1"
    local remote="/tmp/$(basename "$sql_file")"
    _vm_copy_in "$sql_file" "$remote" "$RAC_NODE1"
    _vm_sqlplus "$RAC_NODE1" "$ORACLE_SID1" "/ as sysdba" "$remote"
}

_exec_user() {
    local sql_file="$1"
    local remote="/tmp/$(basename "$sql_file")"
    _vm_copy_in "$sql_file" "$remote" "$RAC_NODE1"
    _vm_sqlplus "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1" "$remote"
}

_oracle_spool_path() {
    echo "/tmp/olr_spool_${SCENARIO}_$$.lst"
}

_fetch_spool() {
    _vm_copy_out "$RAC_NODE1" "$(_oracle_spool_path)" "$1"
}

# Archives in RAC are on the VM host filesystem, not inside containers
_fetch_archive() {
    scp $_SSH_OPTS "${VM_USER}@${VM_HOST}:$1" "$2"
}

# OLR runs via docker with tests/ mounted at _CONTAINER_TESTS
_olr_path() {
    echo "${_CONTAINER_TESTS}/${1#$TESTS_DIR/}"
}

_run_olr_cmd() {
    local host_config="$1"
    docker run --rm \
        -v "$TESTS_DIR:$_CONTAINER_TESTS" \
        --entrypoint /opt/OpenLogReplicator/OpenLogReplicator \
        "$OLR_IMAGE" \
        -f "$(_olr_path "$host_config")"
}

# ---- RAC-specific hook ----

# RAC fix: V$LOG returns multiple rows (one per instance/thread)
patch_gencfg() {
    sed -i "s/FROM SYS.V_\\\$LOG WHERE STATUS = 'CURRENT'/FROM SYS.V_\$LOG WHERE STATUS = 'CURRENT' AND ROWNUM = 1/" "$1"
}

# ---- RAC-specific stage override: block-based scenario execution ----

# Parse .rac.sql into SETUP + ordered NODE blocks
# Outputs numbered files: $WORK_DIR/block_NNN_{setup,node1,node2}.sql
_parse_rac_blocks() {
    local sql_file="$1"
    local block_idx=0
    local current_type=""
    local current_file=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^--[[:space:]]*@SETUP ]]; then
            current_type="setup"
            current_file="$WORK_DIR/block_$(printf '%03d' $block_idx)_setup.sql"
            block_idx=$((block_idx + 1))
            cat > "$current_file" <<'HEADER'
SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF
HEADER
            continue
        elif [[ "$line" =~ ^--[[:space:]]*@NODE1 ]]; then
            current_type="node1"
            current_file="$WORK_DIR/block_$(printf '%03d' $block_idx)_node1.sql"
            block_idx=$((block_idx + 1))
            cat > "$current_file" <<'HEADER'
SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF
HEADER
            continue
        elif [[ "$line" =~ ^--[[:space:]]*@NODE2 ]]; then
            current_type="node2"
            current_file="$WORK_DIR/block_$(printf '%03d' $block_idx)_node2.sql"
            block_idx=$((block_idx + 1))
            cat > "$current_file" <<'HEADER'
SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF
HEADER
            continue
        fi

        if [[ -n "$current_file" ]]; then
            echo "$line" >> "$current_file"
        fi
    done < "$sql_file"

    # Append EXIT to each block
    for f in "$WORK_DIR"/block_*_*.sql; do
        [[ -f "$f" ]] || continue
        echo "" >> "$f"
        echo "EXIT" >> "$f"
    done
}

# Run SQL on a specific node as the test user
_exec_user_on_node() {
    local sql_file="$1"
    local node="$2"
    local sid="$3"
    local conn="$4"
    local remote="/tmp/scenario_block.sql"
    _vm_copy_in "$sql_file" "$remote" "$node"
    _vm_sqlplus "$node" "$sid" "$conn" "$remote"
}

stage_run_scenario() {
    echo "--- Stage 1: Running SQL scenario blocks ---"

    _parse_rac_blocks "$SCENARIO_SQL"

    # Execute blocks in order
    for block_file in "$WORK_DIR"/block_*_*.sql; do
        [[ -f "$block_file" ]] || continue
        block_name=$(basename "$block_file" .sql)
        block_type="${block_name##*_}"  # setup, node1, or node2

        case "$block_type" in
            setup)
                echo "  Running SETUP block on node 1..."
                BLOCK_OUTPUT=$(_exec_user_on_node "$block_file" "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1")
                echo "$BLOCK_OUTPUT"
                SETUP_SCN=$(echo "$BLOCK_OUTPUT" | grep 'FIXTURE_SCN_START:' | head -1 | sed 's/.*FIXTURE_SCN_START:\s*//' | tr -d '[:space:]')
                if [[ -n "$SETUP_SCN" ]]; then
                    START_SCN="$SETUP_SCN"
                fi
                ;;
            node1)
                echo "  Running NODE1 block ($block_name)..."
                BLOCK_OUTPUT=$(_exec_user_on_node "$block_file" "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1")
                echo "$BLOCK_OUTPUT"
                ;;
            node2)
                echo "  Running NODE2 block ($block_name)..."
                BLOCK_OUTPUT=$(_exec_user_on_node "$block_file" "$RAC_NODE2" "$ORACLE_SID2" "$DB_CONN2")
                echo "$BLOCK_OUTPUT"
                ;;
        esac
    done

    if [[ -z "${START_SCN:-}" ]]; then
        echo "ERROR: Could not find FIXTURE_SCN_START in scenario output" >&2
        exit 1
    fi

    # Force log switches on ALL instances (extra switches + longer sleep for RAC)
    echo "  Forcing log switches on all instances..."
    cat > "$WORK_DIR/log_switch.sql" <<'LOGSQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH ALL LOGFILE;
ALTER SYSTEM SWITCH ALL LOGFILE;
BEGIN DBMS_SESSION.SLEEP(5); END;
/
ALTER SYSTEM SWITCH ALL LOGFILE;
BEGIN DBMS_SESSION.SLEEP(5); END;
/
EXIT
LOGSQL
    _exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

    # Get end SCN after log switches
    cat > "$WORK_DIR/get_scn.sql" <<'SCNSQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT current_scn FROM v$database;
EXIT
SCNSQL
    END_SCN=$(_exec_sysdba "$WORK_DIR/get_scn.sql" | tr -d '[:space:]')

    echo "  SCN range: $START_SCN - $END_SCN"
}
