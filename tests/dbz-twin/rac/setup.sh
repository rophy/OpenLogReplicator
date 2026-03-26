#!/usr/bin/env bash
# One-time setup: create c##dbzuser + grants + sentinel table on RAC.
# Run from the project root:
#   tests/environments/rac/debezium/setup.sh
#
# Prerequisites: RAC VM running with containers started.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

VM_HOST="${VM_HOST:-192.168.122.248}"
VM_KEY="${VM_KEY:-$PROJECT_ROOT/oracle-rac/assets/vm-key}"
VM_USER="${VM_USER:-root}"
RAC_NODE1="${RAC_NODE1:-racnodep1}"
ORACLE_SID1="${ORACLE_SID1:-ORCLCDB1}"

SSH_OPTS="-i $VM_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "=== RAC Debezium setup ==="

# Create setup SQL
SETUP_SQL=$(mktemp /tmp/dbz_rac_setup_XXXXXX.sql)
cat > "$SETUP_SQL" <<'SQL'
SET FEEDBACK ON
SET ECHO ON

-- Create common user for Debezium LogMiner + OLR access (CDB level)
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = 'C##DBZUSER';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER c##dbzuser IDENTIFIED BY dbz DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS CONTAINER=ALL';
    DBMS_OUTPUT.PUT_LINE('Created user c##dbzuser');
  ELSE
    DBMS_OUTPUT.PUT_LINE('User c##dbzuser already exists');
  END IF;
END;
/

-- Session and container
GRANT CREATE SESSION TO c##dbzuser CONTAINER=ALL;
GRANT SET CONTAINER TO c##dbzuser CONTAINER=ALL;

-- LogMiner specific
GRANT LOGMINING TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR_D TO c##dbzuser CONTAINER=ALL;

-- V$ views for log mining
GRANT SELECT ON V_$DATABASE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOG_HISTORY TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_LOGS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_CONTENTS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGFILE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$ARCHIVED_LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$ARCHIVE_DEST_STATUS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$TRANSACTION TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$THREAD TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$PARAMETER TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$NLS_PARAMETERS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$TIMEZONE_NAMES TO c##dbzuser CONTAINER=ALL;

-- General access
GRANT SELECT ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ANY TRANSACTION TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ANY DICTIONARY TO c##dbzuser CONTAINER=ALL;
GRANT FLASHBACK ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT_CATALOG_ROLE TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE_CATALOG_ROLE TO c##dbzuser CONTAINER=ALL;
GRANT LOCK ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT CREATE TABLE TO c##dbzuser CONTAINER=ALL;
GRANT ALTER ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT CREATE SEQUENCE TO c##dbzuser CONTAINER=ALL;

-- OLR needs SELECT+FLASHBACK on SYS dictionary base tables (AS OF SCN queries)
-- These must be granted at PDB level
ALTER SESSION SET CONTAINER=ORCLPDB;

GRANT SELECT, FLASHBACK ON SYS.CCOL$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.CDEF$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.COL$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.DEFERRED_STG$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.ECOL$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.LOB$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.LOBCOMPPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.LOBFRAG$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.OBJ$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TAB$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TABCOMPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TABPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TABSUBPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TS$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.USER$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON XDB.XDB$TTSET TO c##dbzuser;

-- OLR also needs FLASHBACK on XDB token tables (dynamic names)
BEGIN
  FOR t IN (SELECT table_name FROM dba_tables WHERE owner='XDB'
            AND (table_name LIKE 'X$NM%' OR table_name LIKE 'X$PT%' OR table_name LIKE 'X$QN%')) LOOP
    EXECUTE IMMEDIATE 'GRANT SELECT, FLASHBACK ON XDB.' || t.table_name || ' TO c##dbzuser';
  END LOOP;
END;
/

GRANT DBA TO c##dbzuser;

-- Sentinel table for completion detection
BEGIN
  EXECUTE IMMEDIATE 'CREATE TABLE olr_test.DEBEZIUM_SENTINEL (
    id NUMBER PRIMARY KEY,
    marker VARCHAR2(100)
  )';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF;
END;
/

ALTER TABLE olr_test.DEBEZIUM_SENTINEL ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

EXIT
SQL

# Copy and execute on RAC node 1
REMOTE="/tmp/dbz_rac_setup.sql"
scp $SSH_OPTS "$SETUP_SQL" "${VM_USER}@${VM_HOST}:${REMOTE}"
ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "chmod 644 ${REMOTE} && podman cp ${REMOTE} ${RAC_NODE1}:${REMOTE}"
ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec ${RAC_NODE1} su - oracle -c 'export ORACLE_SID=${ORACLE_SID1}; sqlplus -S / as sysdba @${REMOTE}'"

rm -f "$SETUP_SQL"

echo ""
echo "=== Setup complete ==="
