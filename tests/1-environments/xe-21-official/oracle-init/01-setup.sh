#!/bin/bash
# Enable archivelog mode, supplemental logging, and create test user.
# Mounted at /opt/oracle/scripts/startup/ — runs every boot after DB is ready.
# Idempotent: checks current state before making changes.
# The container runs as oracle, so sqlplus / as sysdba works directly.

set -e

# Check if archivelog is already enabled
LOG_MODE=$(sqlplus -S / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT log_mode FROM v$database;
EXIT
SQL
)
LOG_MODE=$(echo "$LOG_MODE" | tr -d '[:space:]')

if [ "$LOG_MODE" != "ARCHIVELOG" ]; then
    echo "01-setup.sh: Enabling archivelog mode..."
    sqlplus -S / as sysdba <<'SQL'
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM SET db_recovery_file_dest_size=10G;
SQL
    echo "01-setup.sh: Archivelog mode enabled."
else
    echo "01-setup.sh: Archivelog already enabled, skipping."
fi

# Create test user in PDB (idempotent — ignore if already exists)
sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER=XEPDB1;

-- Create user if not exists (ignore ORA-01920: user name conflicts)
DECLARE
    e_user_exists EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_user_exists, -1920);
BEGIN
    EXECUTE IMMEDIATE 'CREATE USER olr_test IDENTIFIED BY olr_test';
    DBMS_OUTPUT.PUT_LINE('01-setup.sh: User olr_test created.');
EXCEPTION
    WHEN e_user_exists THEN
        DBMS_OUTPUT.PUT_LINE('01-setup.sh: User olr_test already exists.');
END;
/

GRANT CONNECT, RESOURCE TO olr_test;
GRANT UNLIMITED TABLESPACE TO olr_test;
GRANT CREATE TABLE TO olr_test;
GRANT SELECT ON SYS.V_$DATABASE TO olr_test;
EXIT
SQL

echo "01-setup.sh: Setup complete."
