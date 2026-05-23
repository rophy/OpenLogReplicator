#!/usr/bin/env bash
# drivers/base.sh — Base driver with default stage implementations.
#
# All drivers source this file, then override primitives as needed.
# generate.sh sources the driver, which sources this file.
#
# Overridable variables (set BEFORE sourcing base.sh or after):
#   SWITCH_LOGFILE_SQL   — SQL to switch log files (default: ALTER SYSTEM SWITCH LOGFILE)
#   ARCHIVE_LOG_VIEW     — View for archive log queries (default: v$archived_log)
#   ARCHIVE_RETRY_ATTEMPTS — Retries for archive visibility (default: 1)
#   ARCHIVE_MIN_THREADS  — Minimum thread count in archives (default: 1, RAC: 2)
#   FIXTURE_SUFFIX       — Appended to scenario name for fixture name (default: -$ORACLE_TARGET)
#
# Overridable hook:
#   patch_gencfg <path>  — Patch gencfg.sql before running (default: no-op)
#
# Overridable primitives (must be implemented by environment driver):
#   _exec_sysdba <sql_file>       — run SQL as sysdba, return stdout
#   _exec_user <sql_file>         — run SQL as test user, return stdout
#   _oracle_spool_path            — return spool path inside Oracle
#   _fetch_spool <dest>           — copy spool output locally
#   _fetch_archive <src> <dest>   — copy archive log locally
#   _olr_path <host_path>         — map host path to OLR-visible path
#   _run_olr_cmd <config_path>    — execute OLR binary

# ---- Overridable variables (defaults) ----
: "${SWITCH_LOGFILE_SQL:=ALTER SYSTEM SWITCH LOGFILE}"
: "${ARCHIVE_LOG_VIEW:=v\$archived_log}"
: "${ARCHIVE_RETRY_ATTEMPTS:=1}"
: "${ARCHIVE_MIN_THREADS:=1}"
: "${FIXTURE_SUFFIX:=-${ORACLE_TARGET}}"

# Container path prefix — tests/ is mounted here inside OLR container
_CONTAINER_TESTS="${_CONTAINER_TESTS:-/opt/OpenLogReplicator-local/tests}"

# Export UID/GID so docker-compose can set user: on the olr service
export OLR_UID="$(id -u)"
export OLR_GID="$(id -g)"

# ---- Overridable hook ----
patch_gencfg() { :; }

# ---- Primitive stubs (drivers must override) ----
_exec_sysdba()       { echo "ERROR: _exec_sysdba not implemented by driver" >&2; return 1; }
_exec_user()         { echo "ERROR: _exec_user not implemented by driver" >&2; return 1; }
_oracle_spool_path() { echo "ERROR: _oracle_spool_path not implemented by driver" >&2; return 1; }
_fetch_spool()       { echo "ERROR: _fetch_spool not implemented by driver" >&2; return 1; }
_fetch_archive()     { echo "ERROR: _fetch_archive not implemented by driver" >&2; return 1; }
_olr_path()          { echo "ERROR: _olr_path not implemented by driver" >&2; return 1; }
_run_olr_cmd()       { echo "ERROR: _run_olr_cmd not implemented by driver" >&2; return 1; }

# ---- Stage 0: Build LogMiner dictionary (DDL only) ----
stage_build_dictionary() {
    echo "--- Stage 0: Building LogMiner dictionary into redo logs ---"
    cat > "$WORK_DIR/build_dict.sql" <<DICTSQL
SET SERVEROUTPUT ON FEEDBACK OFF
BEGIN
    DBMS_LOGMNR_D.BUILD(OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS);
    DBMS_OUTPUT.PUT_LINE('Dictionary built OK');
END;
/
$SWITCH_LOGFILE_SQL;
BEGIN DBMS_SESSION.SLEEP(2); END;
/
EXIT
DICTSQL
    DICT_OUTPUT=$(_exec_sysdba "$WORK_DIR/build_dict.sql")
    echo "  $DICT_OUTPUT"

    # Record the SCN where dictionary starts
    cat > "$WORK_DIR/dict_scn.sql" <<'DICTSCN'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT MIN(first_change#) FROM v$archived_log
WHERE dictionary_begin = 'YES' AND deleted = 'NO' AND name IS NOT NULL
  AND first_change# = (SELECT MAX(first_change#) FROM v$archived_log
                        WHERE dictionary_begin = 'YES' AND deleted = 'NO');
EXIT
DICTSCN
    DICT_START_SCN=$(_exec_sysdba "$WORK_DIR/dict_scn.sql" | tr -d '[:space:]')
    echo "  Dictionary start SCN: $DICT_START_SCN"
    echo ""
}

# ---- Stage 1: Run SQL scenario ----
stage_run_scenario() {
    echo "--- Stage 1: Running SQL scenario ---"

    if [[ "$SCENARIO_MODE" == "split" ]]; then
        _run_scenario_split
    else
        _run_scenario_single
    fi

    # Force log switches
    echo "  Forcing log switches..."
    cat > "$WORK_DIR/log_switch.sql" <<LOGSQL
SET FEEDBACK OFF
$SWITCH_LOGFILE_SQL;
$SWITCH_LOGFILE_SQL;
BEGIN DBMS_SESSION.SLEEP(3); END;
/
EXIT
LOGSQL
    _exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

    # Get end SCN
    cat > "$WORK_DIR/get_scn.sql" <<'SCNSQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT current_scn FROM v$database;
EXIT
SCNSQL
    END_SCN=$(_exec_sysdba "$WORK_DIR/get_scn.sql" | tr -d '[:space:]')

    echo "  SCN range: $START_SCN - $END_SCN"
}

# Single-file mode: run the .sql as-is, parse FIXTURE_SCN_START from output
_run_scenario_single() {
    if [[ "$MID_SWITCH_COUNT" -gt 0 ]]; then
        echo "  Detected $MID_SWITCH_COUNT @MID_SWITCH marker(s) — running DML in background"
        _exec_user "$SCENARIO_SQL" > "$WORK_DIR/dml_output.txt" 2>&1 &
        DML_PID=$!
        for i in $(seq 1 "$MID_SWITCH_COUNT"); do
            sleep 8
            echo "  Triggering mid-execution log switch #$i"
            cat > "$WORK_DIR/mid_switch.sql" <<MIDSQL
SET FEEDBACK OFF
$SWITCH_LOGFILE_SQL;
EXIT
MIDSQL
            _exec_sysdba "$WORK_DIR/mid_switch.sql" > /dev/null
        done
        wait "$DML_PID" || true
        SCENARIO_OUTPUT=$(cat "$WORK_DIR/dml_output.txt")
    else
        SCENARIO_OUTPUT=$(_exec_user "$SCENARIO_SQL")
    fi
    echo "$SCENARIO_OUTPUT"

    # Parse SCN range from output
    START_SCN=$(echo "$SCENARIO_OUTPUT" | grep 'FIXTURE_SCN_START:' | head -1 | sed 's/.*FIXTURE_SCN_START:\s*//' | tr -d '[:space:]')
    if [[ -z "$START_SCN" ]]; then
        echo "ERROR: Could not find FIXTURE_SCN_START in scenario output" >&2
        exit 1
    fi
}

# Split mode: run setup.sql, log switch, capture SCN, run test.sql
_run_scenario_split() {
    # Run setup.sql if present
    if [[ -n "${SETUP_SQL:-}" ]]; then
        # Wrap setup.sql with SQL*Plus settings and EXIT
        cat > "$WORK_DIR/setup_wrapped.sql" <<'HEADER'
SET FEEDBACK OFF
SET ECHO OFF
HEADER
        cat "$SETUP_SQL" >> "$WORK_DIR/setup_wrapped.sql"
        echo "" >> "$WORK_DIR/setup_wrapped.sql"
        echo "EXIT" >> "$WORK_DIR/setup_wrapped.sql"

        echo "  Running setup.sql..."
        _exec_user "$WORK_DIR/setup_wrapped.sql" > /dev/null

        # Log switch to push setup DDL out of redo
        echo "  Log switch after setup..."
        cat > "$WORK_DIR/setup_switch.sql" <<SWSQL
SET FEEDBACK OFF
$SWITCH_LOGFILE_SQL;
BEGIN DBMS_SESSION.SLEEP(1); END;
/
EXIT
SWSQL
        _exec_sysdba "$WORK_DIR/setup_switch.sql" > /dev/null
    fi

    # Capture start SCN
    cat > "$WORK_DIR/get_start_scn.sql" <<'SCNSQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT current_scn FROM v$database;
EXIT
SCNSQL
    START_SCN=$(_exec_sysdba "$WORK_DIR/get_start_scn.sql" | tr -d '[:space:]')
    echo "  FIXTURE_SCN_START: $START_SCN"

    # Wrap test.sql with SQL*Plus settings and EXIT
    cat > "$WORK_DIR/test_wrapped.sql" <<'HEADER'
SET FEEDBACK OFF
SET ECHO OFF
HEADER
    cat "$SCENARIO_SQL" >> "$WORK_DIR/test_wrapped.sql"
    echo "" >> "$WORK_DIR/test_wrapped.sql"
    echo "EXIT" >> "$WORK_DIR/test_wrapped.sql"

    # Run test.sql
    echo "  Running test.sql..."
    _exec_user "$WORK_DIR/test_wrapped.sql" > /dev/null
}

# ---- Stage 2: Capture archived redo logs ----
stage_capture_archives() {
    echo ""
    echo "--- Stage 2: Capturing archived redo logs ---"
    REDO_DIR="$OUTPUT_BASE/$FIXTURE_NAME/redo"
    rm -rf "$REDO_DIR"
    mkdir -p "$REDO_DIR"

    # Query log_archive_format from Oracle
    cat > "$WORK_DIR/get_archfmt.sql" <<'FMTSQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT value FROM v$parameter WHERE name='log_archive_format';
EXIT
FMTSQL
    LOG_ARCHIVE_FORMAT=$(_exec_sysdba "$WORK_DIR/get_archfmt.sql" | tr -d '[:space:]')
    echo "  Oracle log_archive_format: $LOG_ARCHIVE_FORMAT"

    # Query archive files with thread#/sequence# for format detection
    cat > "$WORK_DIR/find_archives.sql" <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 1000
SELECT name || '|' || thread# || '|' || sequence# || '|' || resetlogs_id
FROM ${ARCHIVE_LOG_VIEW}
WHERE first_change# <= $END_SCN
  AND next_change# >= $START_SCN
  AND deleted = 'NO'
  AND name IS NOT NULL
GROUP BY name, thread#, sequence#, resetlogs_id
ORDER BY thread#, sequence#;
EXIT
SQL

    # Retry loop: RAC archiver may take time to register archives from all threads
    ARCHIVE_LIST=""
    for attempt in $(seq 1 "$ARCHIVE_RETRY_ATTEMPTS"); do
        ARCHIVE_LIST=$(_exec_sysdba "$WORK_DIR/find_archives.sql")
        THREAD_COUNT=$(echo "$ARCHIVE_LIST" | grep -v '^[[:space:]]*$' | cut -d'|' -f2 | sort -u | wc -l)
        if [[ "$THREAD_COUNT" -ge "$ARCHIVE_MIN_THREADS" ]] || [[ "$attempt" -eq "$ARCHIVE_RETRY_ATTEMPTS" ]]; then
            break
        fi
        echo "  Waiting for archives from all threads (attempt $attempt, found $THREAD_COUNT thread(s))..."
        sleep 5
    done

    if [[ -z "$ARCHIVE_LIST" ]]; then
        echo "ERROR: No archive logs found for SCN range" >&2
        exit 1
    fi

    # Detect actual filename prefix by comparing first archive with expected format
    FIRST_LINE=$(echo "$ARCHIVE_LIST" | head -1 | tr -d '[:space:]')
    FIRST_PATH=$(echo "$FIRST_LINE" | cut -d'|' -f1)
    FIRST_THREAD=$(echo "$FIRST_LINE" | cut -d'|' -f2)
    FIRST_SEQ=$(echo "$FIRST_LINE" | cut -d'|' -f3)
    FIRST_RESETLOGS=$(echo "$FIRST_LINE" | cut -d'|' -f4)
    FIRST_FNAME=$(basename "$FIRST_PATH")

    # Construct what the format would produce for this file
    EXPECTED_FNAME=$(echo "$LOG_ARCHIVE_FORMAT" | sed "s/%t/$FIRST_THREAD/;s/%s/$FIRST_SEQ/;s/%r/$FIRST_RESETLOGS/;s/%S/$(printf '%09d' "$FIRST_SEQ")/")
    # Derive prefix: strip expected from actual
    ARCHIVE_PREFIX="${FIRST_FNAME%%$EXPECTED_FNAME}"
    if [[ -n "$ARCHIVE_PREFIX" ]]; then
        echo "  Detected archive filename prefix: '$ARCHIVE_PREFIX'"
        LOG_ARCHIVE_FORMAT="${ARCHIVE_PREFIX}${LOG_ARCHIVE_FORMAT}"
    fi
    echo "  Effective log-archive-format: $LOG_ARCHIVE_FORMAT"

    echo "$ARCHIVE_LIST" | while read -r line; do
        line=$(echo "$line" | tr -d '[:space:]')
        [[ -z "$line" ]] && continue
        arclog=$(echo "$line" | cut -d'|' -f1)
        fname=$(basename "$arclog")
        echo "  Copying: $arclog"
        _fetch_archive "$arclog" "$REDO_DIR/$fname"
    done
    chmod -R a+r "$REDO_DIR"  # Oracle archives are 640; make readable for OLR container
    echo "  Redo logs saved to: $REDO_DIR"
}

# ---- Stage 3: Generate schema file ----
stage_generate_schema() {
    echo ""
    echo "--- Stage 3: Schema generation ---"
    SCHEMA_DIR="$OUTPUT_BASE/$FIXTURE_NAME/schema"
    rm -rf "$SCHEMA_DIR"
    mkdir -p "$SCHEMA_DIR"

    # Patch gencfg.sql with test parameters
    cp "$PROJECT_ROOT/scripts/gencfg.sql" "$WORK_DIR/gencfg.sql"

    sed -i "s/v_NAME := 'DB'/v_NAME := 'TEST'/" "$WORK_DIR/gencfg.sql"
    sed -i "s/v_USERNAME_LIST := VARCHAR2TABLE('USR1', 'USR2')/v_USERNAME_LIST := VARCHAR2TABLE('$SCHEMA_OWNER')/" "$WORK_DIR/gencfg.sql"
    sed -i "s/SELECT CURRENT_SCN INTO v_SCN FROM SYS.V_\\\$DATABASE/-- SELECT CURRENT_SCN INTO v_SCN FROM SYS.V_\$DATABASE/" "$WORK_DIR/gencfg.sql"
    sed -i "s/-- v_SCN := 12345678/v_SCN := $START_SCN/" "$WORK_DIR/gencfg.sql"

    # Add PDB session switch and settings before the DECLARE block
    sed -i '/^SET LINESIZE/i ALTER SESSION SET CONTAINER='"$PDB_NAME"';\nSET FEEDBACK OFF\nSET ECHO OFF' "$WORK_DIR/gencfg.sql"

    # Driver hook for additional patches (e.g., RAC ROWNUM fix)
    patch_gencfg "$WORK_DIR/gencfg.sql"

    # Add EXIT at end
    echo "EXIT;" >> "$WORK_DIR/gencfg.sql"

    echo "  Running gencfg.sql..."
    GENCFG_OUTPUT=$(_exec_sysdba "$WORK_DIR/gencfg.sql")

    # Extract JSON content (starts with {"database":)
    SCHEMA_FILE="$SCHEMA_DIR/TEST-chkpt-${START_SCN}.json"
    echo "$GENCFG_OUTPUT" | sed -n '/^{"database"/,$p' > "$SCHEMA_FILE"

    if [[ ! -s "$SCHEMA_FILE" ]]; then
        echo "ERROR: gencfg.sql produced no JSON output" >&2
        echo "Output was:" >&2
        echo "$GENCFG_OUTPUT" >&2
        exit 1
    fi

    # Fix seq to 0 for batch mode
    python3 -c "
import json, sys
with open('$SCHEMA_FILE') as f:
    data = json.load(f)
data['seq'] = 0
with open('$SCHEMA_FILE', 'w') as f:
    json.dump(data, f, separators=(',', ':'))
"
    echo "  Schema file: $SCHEMA_FILE ($(wc -c < "$SCHEMA_FILE") bytes)"
}

# ---- Stage 4: Run LogMiner extraction ----
stage_run_logminer() {
    echo ""
    echo "--- Stage 4: Running LogMiner extraction ---"

    if [[ "$DDL_MODE" -eq 1 ]]; then
        LM_ARCHIVE_FILTER="first_change# <= $END_SCN AND next_change# >= $DICT_START_SCN"
        LM_OPTIONS="DBMS_LOGMNR.DICT_FROM_REDO_LOGS + DBMS_LOGMNR.DDL_DICT_TRACKING + DBMS_LOGMNR.NO_ROWID_IN_STMT + DBMS_LOGMNR.COMMITTED_DATA_ONLY"
        LM_MODE_DESC="DICT_FROM_REDO_LOGS + DDL_DICT_TRACKING"
    else
        LM_ARCHIVE_FILTER="first_change# <= $END_SCN AND next_change# >= $START_SCN"
        LM_OPTIONS="DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG + DBMS_LOGMNR.NO_ROWID_IN_STMT + DBMS_LOGMNR.COMMITTED_DATA_ONLY"
        LM_MODE_DESC="DICT_FROM_ONLINE_CATALOG"
    fi
    echo "  LogMiner mode: $LM_MODE_DESC"

    cat > "$WORK_DIR/logminer_run.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 32767
SET LONG 100000
SET LONGCHUNKSIZE 100000
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
        WHERE $LM_ARCHIVE_FILTER
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
        options  => $LM_OPTIONS
    );
END;
/

SPOOL $(_oracle_spool_path)

SELECT TO_CLOB(scn || '|' || operation || '|' || seg_owner || '|' || table_name || '|' || xid || '|') ||
       REPLACE(REPLACE(sql_redo, CHR(10), ' '), CHR(13), '') || '|' ||
       REPLACE(REPLACE(NVL(sql_undo, ''), CHR(10), ' '), CHR(13), '') || '|' ||
       row_id
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

    echo "  Running LogMiner..."
    LM_OUTPUT=$(_exec_sysdba "$WORK_DIR/logminer_run.sql")
    echo "$LM_OUTPUT" | head -20 || true

    _fetch_spool "$WORK_DIR/logminer_raw.lst"

    python3 "$SCRIPT_DIR/logminer2json.py" "$WORK_DIR/logminer_raw.lst" "$WORK_DIR/logminer.json"
    LM_COUNT=$(wc -l < "$WORK_DIR/logminer.json")
    echo "  LogMiner records: $LM_COUNT"
}

# ---- Stage 5: Run OLR in batch mode ----
stage_run_olr() {
    echo ""
    echo "--- Stage 5: Running OLR ---"

    # Backup schema file before OLR (OLR modifies the schema dir with checkpoints)
    cp "$SCHEMA_FILE" "$WORK_DIR/schema_backup.json"

    # Translate host paths to OLR-visible paths via driver
    C_REDO=$(_olr_path "$REDO_DIR")
    C_SCHEMA=$(_olr_path "$SCHEMA_DIR")
    OLR_OUTPUT="$WORK_DIR/olr_output.json"
    C_OUTPUT=$(_olr_path "$OLR_OUTPUT")

    # Build redo-log JSON array using OLR-visible paths
    REDO_FILES_JSON=""
    for f in "$REDO_DIR"/*; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        if [[ -n "$REDO_FILES_JSON" ]]; then
            REDO_FILES_JSON="$REDO_FILES_JSON, "
        fi
        REDO_FILES_JSON="$REDO_FILES_JSON\"$C_REDO/$fname\""
    done

    # Config uses OLR-visible paths
    cat > "$WORK_DIR/olr_config.json" <<EOF
{
  "version": "1.9.0",
  "log-level": 3,
  "memory": {
    "min-mb": 32,
    "max-mb": 256
  },
  "state": {
    "type": "disk",
    "path": "$C_SCHEMA"
  },
  "source": [
    {
      "alias": "S1",
      "name": "TEST",
      "reader": {
        "type": "batch",
        "redo-log": [$REDO_FILES_JSON],
        "log-archive-format": "$LOG_ARCHIVE_FORMAT",
        "start-scn": $START_SCN
      },
      "format": {
        "type": "json",
        "scn": 1,
        "timestamp": 7,
        "timestamp-metadata": 7,
        "xid": 1,
        "json-number-type": 1
      },
      "filter": {
        "table": [
          {"owner": "$SCHEMA_OWNER", "table": ".*"}
        ]
      }
    }
  ],
  "target": [
    {
      "alias": "T1",
      "source": "S1",
      "writer": {
        "type": "file",
        "output": "$C_OUTPUT",
        "new-line": 1,
        "append": 1
      }
    }
  ]
}
EOF

    echo "  Running OLR (driver: $ORACLE_DRIVER)..."
    if ! _run_olr_cmd "$WORK_DIR/olr_config.json" > "$WORK_DIR/olr_stdout.log" 2>&1; then
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

    # Clean up runtime checkpoint files and restore original schema
    rm -f "$SCHEMA_DIR"/TEST-chkpt.json "$SCHEMA_DIR"/TEST-chkpt-*.json
    cp "$WORK_DIR/schema_backup.json" "$SCHEMA_FILE"
}
