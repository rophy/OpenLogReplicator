#!/usr/bin/env bash
# generate.sh — Orchestrate fixture generation for OLR regression tests.
#
# Usage: ./generate.sh <scenario-name>
# Example: ./generate.sh basic-crud
#
# Environment variables:
#   VM_HOST   — Oracle VM IP (default: 192.168.122.248)
#   VM_KEY    — SSH key path (default: oracle-rac/vm-key)
#   VM_USER   — SSH user (default: root)
#   OLR_BIN   — Path to OLR binary (default: auto-detect from build)
#   DB_CONN   — sqlplus connect string for test user (default: olr_test/olr_test@//localhost:1521/ORCLPDB)
#   SYS_CONN  — sqlplus connect string for sysdba (default: sys/oracle@//localhost:1521/ORCLPDB as sysdba)
#   SCHEMA_OWNER — Schema owner for LogMiner filter (default: OLR_TEST)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$PROJECT_ROOT/tests/data"

# Defaults
VM_HOST="${VM_HOST:-192.168.122.248}"
VM_KEY="${VM_KEY:-$PROJECT_ROOT/oracle-rac/vm-key}"
VM_USER="${VM_USER:-root}"
SCHEMA_OWNER="${SCHEMA_OWNER:-OLR_TEST}"

# DB connection strings — these run ON the VM via SSH
DB_CONN="${DB_CONN:-olr_test/olr_test@//localhost:1521/ORCLPDB}"
SYS_CONN="${SYS_CONN:-sys/oracle@//localhost:1521/ORCLPDB as sysdba}"

# OLR binary — try to find it
if [[ -z "${OLR_BIN:-}" ]]; then
    for candidate in \
        "$PROJECT_ROOT/build/src/OpenLogReplicator" \
        "$PROJECT_ROOT/cmake-build-debug/src/OpenLogReplicator" \
        "$PROJECT_ROOT/cmake-build-release/src/OpenLogReplicator"; do
        if [[ -x "$candidate" ]]; then
            OLR_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "${OLR_BIN:-}" ]]; then
    echo "ERROR: OLR binary not found. Set OLR_BIN or build the project first." >&2
    exit 1
fi

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

echo "=== Fixture generation: $SCENARIO ==="
echo "  VM: $VM_HOST"
echo "  Work dir: $WORK_DIR"
echo ""

# ---- Stage 1: Run SQL scenario on VM ----
echo "--- Stage 1: Running SQL scenario ---"
scp $SSH_OPTS "$SCENARIO_SQL" "${VM_USER}@${VM_HOST}:/tmp/scenario.sql"

# Run scenario SQL via sqlplus on the VM.
# The Oracle env is set up via /etc/profile.d or we source it explicitly.
SCENARIO_OUTPUT=$(ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" bash -s <<REMOTE_EOF
export ORACLE_HOME=/u01/app/oracle/product/23ai/dbhome_1
export PATH=\$ORACLE_HOME/bin:\$PATH
export ORACLE_SID=ORCLCDB1
sqlplus -S "$DB_CONN" @/tmp/scenario.sql
REMOTE_EOF
)
echo "$SCENARIO_OUTPUT"

# Parse SCN range from output
SCN_RANGE=$(echo "$SCENARIO_OUTPUT" | grep 'FIXTURE_SCN_RANGE:' | head -1)
if [[ -z "$SCN_RANGE" ]]; then
    echo "ERROR: Could not find FIXTURE_SCN_RANGE in scenario output" >&2
    exit 1
fi

START_SCN=$(echo "$SCN_RANGE" | sed 's/.*FIXTURE_SCN_RANGE:\s*//' | cut -d'-' -f1 | tr -d ' ')
END_SCN=$(echo "$SCN_RANGE" | sed 's/.*FIXTURE_SCN_RANGE:\s*//' | cut -d'-' -f2 | tr -d ' ')
echo "  SCN range: $START_SCN - $END_SCN"

# ---- Stage 2: Capture archived redo logs ----
echo ""
echo "--- Stage 2: Capturing archived redo logs ---"
REDO_DIR="$DATA_DIR/redo/$SCENARIO"
mkdir -p "$REDO_DIR"

# Find archive logs covering SCN range
ARCHIVE_LIST=$(ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" bash -s <<REMOTE_EOF
export ORACLE_HOME=/u01/app/oracle/product/23ai/dbhome_1
export PATH=\$ORACLE_HOME/bin:\$PATH
export ORACLE_SID=ORCLCDB1
sqlplus -S "/ as sysdba" <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 1000
SELECT name FROM v\$archived_log
WHERE first_change# <= $END_SCN
  AND next_change# >= $START_SCN
  AND deleted = 'NO'
  AND name IS NOT NULL
ORDER BY thread#, sequence#;
SQL
REMOTE_EOF
)

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

# ---- Stage 3: Generate schema (if needed) ----
echo ""
echo "--- Stage 3: Schema generation ---"
SCHEMA_DIR="$DATA_DIR/schema/$SCENARIO"
mkdir -p "$SCHEMA_DIR"
echo "  Schema dir created: $SCHEMA_DIR (using flags=2 schemaless mode)"

# ---- Stage 4: Run LogMiner extraction ----
echo ""
echo "--- Stage 4: Running LogMiner extraction ---"
scp $SSH_OPTS "$SCRIPT_DIR/lib/logminer-extract.sql" "${VM_USER}@${VM_HOST}:/tmp/logminer-extract.sql"

ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" bash -s <<REMOTE_EOF
export ORACLE_HOME=/u01/app/oracle/product/23ai/dbhome_1
export PATH=\$ORACLE_HOME/bin:\$PATH
export ORACLE_SID=ORCLCDB1
sqlplus -S "$SYS_CONN" @/tmp/logminer-extract.sql $START_SCN $END_SCN /tmp/logminer_out.lst $SCHEMA_OWNER
REMOTE_EOF

scp $SSH_OPTS "${VM_USER}@${VM_HOST}:/tmp/logminer_out.lst" "$WORK_DIR/logminer_raw.lst"

# Convert to JSON
python3 "$SCRIPT_DIR/logminer2json.py" "$WORK_DIR/logminer_raw.lst" "$WORK_DIR/logminer.json"
LM_COUNT=$(wc -l < "$WORK_DIR/logminer.json")
echo "  LogMiner records: $LM_COUNT"

# ---- Stage 5: Run OLR in batch mode ----
echo ""
echo "--- Stage 5: Running OLR ---"

# Collect redo log file paths
REDO_FILES=""
for f in "$REDO_DIR"/*; do
    [[ -f "$f" ]] || continue
    if [[ -n "$REDO_FILES" ]]; then
        REDO_FILES="$REDO_FILES, "
    fi
    REDO_FILES="$REDO_FILES\"$f\""
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
        "redo-log": [$REDO_FILES],
        "log-archive-format": ""
      },
      "format": {
        "type": "json",
        "scn": 1,
        "timestamp": 7,
        "xid": 1
      },
      "flags": 2,
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
        "path": "$SCHEMA_DIR"
      }
    }
  ],
  "target": [
    {
      "alias": "T1",
      "source": "S1",
      "writer": {
        "type": "file",
        "output": "$OLR_OUTPUT",
        "new-line": 1,
        "append": 0
      }
    }
  ]
}
EOF

echo "  Running: $OLR_BIN -r -f $WORK_DIR/olr_config.json"
if ! "$OLR_BIN" -r -f "$WORK_DIR/olr_config.json" > "$WORK_DIR/olr_stdout.log" 2>&1; then
    echo "ERROR: OLR exited with non-zero status" >&2
    echo "  OLR output:" >&2
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
    echo ""
    echo "=== PASS: Fixture '$SCENARIO' generated successfully ==="

    # Also save LogMiner reference for debugging
    cp "$WORK_DIR/logminer.json" "$EXPECTED_DIR/logminer-reference.json"
    echo "  LogMiner reference saved: $EXPECTED_DIR/logminer-reference.json"
else
    echo "--- Stage 7: SKIPPED (comparison failed) ---"
    echo ""
    echo "=== FAIL: Fixture '$SCENARIO' comparison failed ==="
    echo "  LogMiner JSON: $WORK_DIR/logminer.json"
    echo "  OLR output:    $OLR_OUTPUT"
    echo "  OLR log:       $WORK_DIR/olr_stdout.log"
    echo ""
    echo "Debug: inspect the files above, then re-run after fixing."
    # Don't clean up on failure
    trap - EXIT
    exit 1
fi
