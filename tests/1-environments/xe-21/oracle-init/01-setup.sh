#!/bin/bash
# Enable archivelog mode and supplemental logging for OLR testing.
# Runs as part of gvenzl/oracle-xe container initialization.

sqlplus -S / as sysdba <<'SQL'
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM SET db_recovery_file_dest_size=10G;

-- Grant PDB user access to v$database for SCN queries in test scenarios
ALTER SESSION SET CONTAINER=XEPDB1;
GRANT SELECT ON SYS.V_$DATABASE TO olr_test;
SQL
