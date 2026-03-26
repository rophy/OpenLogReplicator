#!/bin/bash
# Enable supplemental logging and create test user for OLR testing.
# Mounted at /opt/oracle/scripts/startup/ — runs every boot after DB is ready.
# ENABLE_ARCHIVELOG=true in docker-compose handles archivelog mode.
# The container runs as oracle, so sqlplus / as sysdba works directly.

set -e

# Enable supplemental logging (idempotent)
sqlplus -S / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM SET db_recovery_file_dest_size=10G;
SQL

# Create test user in PDB (idempotent — ignore if already exists)
sqlplus -S / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
ALTER SESSION SET CONTAINER=ORCLPDB1;

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
