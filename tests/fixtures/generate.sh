#!/usr/bin/env bash
# generate.sh — Orchestrate fixture generation for OLR regression tests.
#
# Usage: ./generate.sh <scenario-name>
# Example: ./generate.sh basic-crud
#
# This script is designed for the Oracle RAC VM setup where Oracle runs
# inside podman containers (racnodep1, racnodep2). All sqlplus commands
# are executed via: podman exec <container> su - oracle -c '...'
#
# Environment variables:
#   VM_HOST       — Oracle VM IP (default: 192.168.122.248)
#   VM_KEY        — SSH key path (default: oracle-rac/assets/vm-key)
#   VM_USER       — SSH user (default: root)
#   OLR_IMAGE     — Docker image for OLR (default: rophy/openlogreplicator:1.8.7)
#   RAC_NODE      — Container name for sqlplus (default: racnodep1)
#   ORACLE_SID    — Oracle SID inside container (default: ORCLCDB1)
#   DB_CONN       — sqlplus connect string for test user (default: olr_test/olr_test@//racnodep1:1521/ORCLPDB)
#   SCHEMA_OWNER  — Schema owner for LogMiner filter (default: OLR_TEST)
#   DML_THREAD    — Thread number that generated the DML (default: 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$PROJECT_ROOT/tests/data"

# Defaults
VM_HOST="${VM_HOST:-192.168.122.248}"
VM_KEY="${VM_KEY:-$PROJECT_ROOT/oracle-rac/assets/vm-key}"
VM_USER="${VM_USER:-root}"
OLR_IMAGE="${OLR_IMAGE:-rophy/openlogreplicator:1.8.7}"
RAC_NODE="${RAC_NODE:-racnodep1}"
ORACLE_SID="${ORACLE_SID:-ORCLCDB1}"
DB_CONN="${DB_CONN:-olr_test/olr_test@//racnodep1:1521/ORCLPDB}"
SCHEMA_OWNER="${SCHEMA_OWNER:-OLR_TEST}"
DML_THREAD="${DML_THREAD:-1}"

SSH_OPTS="-i $VM_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

SCENARIO="${1:?Usage: $0 <scenario-name>}"
SCENARIO_SQL="$SCRIPT_DIR/scenarios/${SCENARIO}.sql"

if [[ ! -f "$SCENARIO_SQL" ]]; then
    echo "ERROR: Scenario file not found: $SCENARIO_SQL" >&2
    echo "Available scenarios:" >&2
    ls "$SCRIPT_DIR/scenarios/"*.sql 2>/dev/null | sed 's/.*\//  /' | sed 's/\.sql$//' >&2
    exit 1
fi

# Working directory for this run
WORK_DIR=$(mktemp -d "/tmp/olr_fixture_${SCENARIO}_XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

# Helper: run sqlplus inside the RAC container as oracle user
vm_sqlplus() {
    local conn="$1"
    local sql_file="$2"
    ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $RAC_NODE su - oracle -c 'export ORACLE_SID=$ORACLE_SID; sqlplus -S \"$conn\" @$sql_file'"
}

# Helper: copy a local file into the RAC container via the VM
vm_copy_in() {
    local local_path="$1"
    local container_path="$2"
    scp $SSH_OPTS "$local_path" "${VM_USER}@${VM_HOST}:/tmp/_fixture_tmp"
    ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" "podman cp /tmp/_fixture_tmp ${RAC_NODE}:${container_path}"
}

# Helper: copy a file from the RAC container to local
vm_copy_out() {
    local container_path="$1"
    local local_path="$2"
    ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" "podman cp ${RAC_NODE}:${container_path} /tmp/_fixture_tmp"
    scp $SSH_OPTS "${VM_USER}@${VM_HOST}:/tmp/_fixture_tmp" "$local_path"
}

echo "=== Fixture generation: $SCENARIO ==="
echo "  VM: $VM_HOST"
echo "  Container: $RAC_NODE"
echo "  Work dir: $WORK_DIR"
echo ""

# ---- Stage 1: Run SQL scenario ----
echo "--- Stage 1: Running SQL scenario ---"
vm_copy_in "$SCENARIO_SQL" "/tmp/scenario.sql"
SCENARIO_OUTPUT=$(vm_sqlplus "$DB_CONN" "/tmp/scenario.sql")
echo "$SCENARIO_OUTPUT"

# Parse SCN range from output
START_SCN=$(echo "$SCENARIO_OUTPUT" | grep 'FIXTURE_SCN_START:' | head -1 | sed 's/.*FIXTURE_SCN_START:\s*//' | tr -d '[:space:]')
if [[ -z "$START_SCN" ]]; then
    echo "ERROR: Could not find FIXTURE_SCN_START in scenario output" >&2
    exit 1
fi

# Force log switches from CDB root (required — can't run from PDB)
echo "  Forcing log switches..."
cat > "$WORK_DIR/log_switch.sql" <<'LOGSQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
BEGIN DBMS_SESSION.SLEEP(3); END;
/
EXIT
LOGSQL
vm_copy_in "$WORK_DIR/log_switch.sql" "/tmp/log_switch.sql"
vm_sqlplus "/ as sysdba" "/tmp/log_switch.sql"

# Get end SCN after log switches
cat > "$WORK_DIR/get_scn.sql" <<'SCNSQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT current_scn FROM v$database;
EXIT
SCNSQL
vm_copy_in "$WORK_DIR/get_scn.sql" "/tmp/get_scn.sql"
END_SCN=$(vm_sqlplus "/ as sysdba" "/tmp/get_scn.sql" | tr -d '[:space:]')

echo "  SCN range: $START_SCN - $END_SCN"

# ---- Stage 2: Capture archived redo logs ----
echo ""
echo "--- Stage 2: Capturing archived redo logs ---"
REDO_DIR="$DATA_DIR/redo/$SCENARIO"
mkdir -p "$REDO_DIR"

# Query V$ARCHIVED_LOG for files covering the SCN range (DML thread only)
cat > "$WORK_DIR/find_archives.sql" <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 1000
SELECT name FROM v\$archived_log
WHERE first_change# <= $END_SCN
  AND next_change# >= $START_SCN
  AND thread# = $DML_THREAD
  AND deleted = 'NO'
  AND name IS NOT NULL
ORDER BY thread#, sequence#;
EXIT
SQL

vm_copy_in "$WORK_DIR/find_archives.sql" "/tmp/find_archives.sql"
ARCHIVE_LIST=$(vm_sqlplus "/ as sysdba" "/tmp/find_archives.sql")

if [[ -z "$ARCHIVE_LIST" ]]; then
    echo "ERROR: No archive logs found for SCN range" >&2
    exit 1
fi

echo "$ARCHIVE_LIST" | while read -r arclog; do
    arclog=$(echo "$arclog" | tr -d '[:space:]')
    [[ -z "$arclog" ]] && continue
    echo "  Copying: $arclog"
    scp $SSH_OPTS "${VM_USER}@${VM_HOST}:${arclog}" "$REDO_DIR/"
done
echo "  Redo logs saved to: $REDO_DIR"

# ---- Stage 3: Generate schema file ----
echo ""
echo "--- Stage 3: Schema generation ---"
SCHEMA_DIR="$DATA_DIR/schema/$SCENARIO"
rm -rf "$SCHEMA_DIR"
mkdir -p "$SCHEMA_DIR"

# Create modified gencfg.sql with correct parameters and RAC fix
cp "$PROJECT_ROOT/scripts/gencfg.sql" "$WORK_DIR/gencfg.sql"

# Patch parameters: name, users, SCN
sed -i "s/v_NAME := 'DB'/v_NAME := 'TEST'/" "$WORK_DIR/gencfg.sql"
sed -i "s/v_USERNAME_LIST := VARCHAR2TABLE('USR1', 'USR2')/v_USERNAME_LIST := VARCHAR2TABLE('$SCHEMA_OWNER')/" "$WORK_DIR/gencfg.sql"
sed -i "s/SELECT CURRENT_SCN INTO v_SCN FROM SYS.V_\\\$DATABASE/-- SELECT CURRENT_SCN INTO v_SCN FROM SYS.V_\$DATABASE/" "$WORK_DIR/gencfg.sql"
sed -i "s/-- v_SCN := 12345678/v_SCN := $START_SCN/" "$WORK_DIR/gencfg.sql"

# RAC fix: V$LOG returns multiple rows (one per instance/thread)
sed -i "s/FROM SYS.V_\\\$LOG WHERE STATUS = 'CURRENT'/FROM SYS.V_\$LOG WHERE STATUS = 'CURRENT' AND ROWNUM = 1/" "$WORK_DIR/gencfg.sql"

# Add PDB session and settings
sed -i '/^SET LINESIZE/i ALTER SESSION SET CONTAINER=ORCLPDB;\nSET FEEDBACK OFF\nSET ECHO OFF' "$WORK_DIR/gencfg.sql"

# Add EXIT at end
echo "EXIT;" >> "$WORK_DIR/gencfg.sql"

vm_copy_in "$WORK_DIR/gencfg.sql" "/tmp/gencfg.sql"

echo "  Running gencfg.sql..."
GENCFG_OUTPUT=$(vm_sqlplus "/ as sysdba" "/tmp/gencfg.sql")

# Extract JSON content (starts with {"database":)
SCHEMA_FILE="$SCHEMA_DIR/TEST-chkpt-${START_SCN}.json"
echo "$GENCFG_OUTPUT" | sed -n '/^{"database"/,$p' > "$SCHEMA_FILE"

# Fix seq to 0 for batch mode (gencfg records current log seq which may not match archives)
python3 -c "
import json
with open('$SCHEMA_FILE') as f:
    data = json.load(f)
data['seq'] = 0
with open('$SCHEMA_FILE', 'w') as f:
    json.dump(data, f, separators=(',', ':'))
"
echo "  Schema file: $SCHEMA_FILE ($(wc -c < "$SCHEMA_FILE") bytes)"

# ---- Stage 4: Run LogMiner extraction ----
echo ""
echo "--- Stage 4: Running LogMiner extraction ---"

cat > "$WORK_DIR/logminer_run.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 32767
SET PAGESIZE 0
SET TRIMSPOOL ON
SET TRIMOUT ON
SET FEEDBACK OFF
SET ECHO OFF
SET HEADING OFF
SET VERIFY OFF

DECLARE
    v_count NUMBER := 0;
BEGIN
    FOR rec IN (
        SELECT name FROM v\$archived_log
        WHERE first_change# <= $END_SCN
          AND next_change# >= $START_SCN
          AND deleted = 'NO'
          AND name IS NOT NULL
        ORDER BY sequence#
    ) LOOP
        DBMS_LOGMNR.ADD_LOGFILE(
            logfilename => rec.name,
            options     => CASE WHEN v_count = 0
                                THEN DBMS_LOGMNR.NEW
                                ELSE DBMS_LOGMNR.ADDFILE
                           END
        );
        v_count := v_count + 1;
        DBMS_OUTPUT.PUT_LINE('Added log: ' || rec.name);
    END LOOP;

    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: No archive logs found for SCN range');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('Starting LogMiner with ' || v_count || ' log file(s)');

    DBMS_LOGMNR.START_LOGMNR(
        startScn => $START_SCN,
        endScn   => $END_SCN,
        options  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                  + DBMS_LOGMNR.NO_ROWID_IN_STMT
                  + DBMS_LOGMNR.COMMITTED_DATA_ONLY
    );
END;
/

SPOOL /tmp/logminer_out.lst

SELECT scn || '|' ||
       operation || '|' ||
       seg_owner || '|' ||
       table_name || '|' ||
       xid || '|' ||
       REPLACE(REPLACE(sql_redo, CHR(10), ' '), CHR(13), '') || '|' ||
       REPLACE(REPLACE(NVL(sql_undo, ''), CHR(10), ' '), CHR(13), '')
FROM v\$logmnr_contents
WHERE seg_owner = UPPER('$SCHEMA_OWNER')
  AND operation IN ('INSERT', 'UPDATE', 'DELETE')
ORDER BY scn, xid, sequence#;

SPOOL OFF

BEGIN
    DBMS_LOGMNR.END_LOGMNR;
END;
/

EXIT
SQL

vm_copy_in "$WORK_DIR/logminer_run.sql" "/tmp/logminer_run.sql"

echo "  Running LogMiner..."
LM_OUTPUT=$(vm_sqlplus "/ as sysdba" "/tmp/logminer_run.sql")
echo "$LM_OUTPUT" | head -20 || true

vm_copy_out "/tmp/logminer_out.lst" "$WORK_DIR/logminer_raw.lst"

python3 "$SCRIPT_DIR/logminer2json.py" "$WORK_DIR/logminer_raw.lst" "$WORK_DIR/logminer.json"
LM_COUNT=$(wc -l < "$WORK_DIR/logminer.json")
echo "  LogMiner records: $LM_COUNT"

# ---- Stage 5: Run OLR in batch mode (via Docker) ----
echo ""
echo "--- Stage 5: Running OLR ---"

# Backup schema file before OLR (OLR modifies the schema dir)
cp "$SCHEMA_FILE" "$WORK_DIR/schema_backup.json"

# Build redo-log JSON array from files
REDO_FILES_JSON=""
for f in "$REDO_DIR"/*; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f")
    if [[ -n "$REDO_FILES_JSON" ]]; then
        REDO_FILES_JSON="$REDO_FILES_JSON, "
    fi
    REDO_FILES_JSON="$REDO_FILES_JSON\"/data/redo/$fname\""
done

OLR_OUTPUT="$WORK_DIR/olr_output.json"

cat > "$WORK_DIR/olr_config.json" <<EOF
{
  "version": "1.8.7",
  "log-level": 3,
  "source": [
    {
      "alias": "S1",
      "name": "TEST",
      "reader": {
        "type": "batch",
        "redo-log": [$REDO_FILES_JSON],
        "log-archive-format": "%t_%s_%r.arc",
        "start-scn": $START_SCN
      },
      "format": {
        "type": "json",
        "scn": 1,
        "timestamp": 7,
        "xid": 1
      },
      "memory": {
        "min-mb": 32,
        "max-mb": 256
      },
      "filter": {
        "table": [
          {"owner": "$SCHEMA_OWNER", "table": ".*"}
        ]
      },
      "state": {
        "type": "disk",
        "path": "/data/schema"
      }
    }
  ],
  "target": [
    {
      "alias": "T1",
      "source": "S1",
      "writer": {
        "type": "file",
        "output": "/data/output/olr_output.json",
        "new-line": 1,
        "append": 1
      }
    }
  ]
}
EOF

echo "  Running: docker run $OLR_IMAGE"
if ! docker run --rm \
    -v "$WORK_DIR/olr_config.json:/data/config.json:ro" \
    -v "$REDO_DIR:/data/redo:ro" \
    -v "$SCHEMA_DIR:/data/schema" \
    -v "$WORK_DIR:/data/output" \
    --entrypoint /opt/OpenLogReplicator/OpenLogReplicator \
    "$OLR_IMAGE" \
    -f /data/config.json > "$WORK_DIR/olr_stdout.log" 2>&1; then
    echo "ERROR: OLR exited with non-zero status" >&2
    cat "$WORK_DIR/olr_stdout.log" >&2
    exit 1
fi

if [[ ! -f "$OLR_OUTPUT" ]]; then
    echo "ERROR: OLR did not produce output file" >&2
    cat "$WORK_DIR/olr_stdout.log" >&2
    exit 1
fi

OLR_LINES=$(wc -l < "$OLR_OUTPUT")
echo "  OLR output lines: $OLR_LINES"

# Clean up runtime checkpoint files from schema dir and restore original
rm -f "$SCHEMA_DIR"/TEST-chkpt.json "$SCHEMA_DIR"/TEST-chkpt-*.json
cp "$WORK_DIR/schema_backup.json" "$SCHEMA_FILE"

# ---- Stage 6: Compare ----
echo ""
echo "--- Stage 6: Comparing LogMiner vs OLR ---"
if python3 "$SCRIPT_DIR/compare.py" "$WORK_DIR/logminer.json" "$OLR_OUTPUT"; then
    COMPARE_RESULT=0
else
    COMPARE_RESULT=1
fi

# ---- Stage 7: Save golden file if passing ----
echo ""
if [[ $COMPARE_RESULT -eq 0 ]]; then
    echo "--- Stage 7: Saving golden file ---"
    EXPECTED_DIR="$DATA_DIR/expected/$SCENARIO"
    mkdir -p "$EXPECTED_DIR"
    cp "$OLR_OUTPUT" "$EXPECTED_DIR/output.json"
    echo "  Golden file saved: $EXPECTED_DIR/output.json"

    cp "$WORK_DIR/logminer.json" "$EXPECTED_DIR/logminer-reference.json"
    echo "  LogMiner reference saved: $EXPECTED_DIR/logminer-reference.json"
    echo ""
    echo "=== PASS: Fixture '$SCENARIO' generated successfully ==="
else
    echo "--- Stage 7: SKIPPED (comparison failed) ---"
    echo ""
    echo "=== FAIL: Fixture '$SCENARIO' comparison failed ==="
    echo "  LogMiner JSON: $WORK_DIR/logminer.json"
    echo "  OLR output:    $OLR_OUTPUT"
    echo "  OLR log:       $WORK_DIR/olr_stdout.log"
    echo ""
    echo "Debug: inspect the files above, then re-run after fixing."
    trap - EXIT
    exit 1
fi
