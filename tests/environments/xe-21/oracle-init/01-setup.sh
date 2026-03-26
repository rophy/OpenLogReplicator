#!/bin/bash
# Enable archivelog mode and supplemental logging for OLR testing.
# Runs as part of gvenzl/oracle-xe container initialization.
# Idempotent: skips DB bounce if archivelog is already enabled.

set -e

# Check if archivelog mode is already enabled
ARCHIVELOG=$(sqlplus -S / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT LOG_MODE FROM V$DATABASE;
SQL
)

if echo "$ARCHIVELOG" | grep -q "NOARCHIVELOG"; then
    echo "01-setup.sh: Enabling archivelog mode (requires DB bounce)..."
    sqlplus -S / as sysdba <<'SQL'
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
SQL
fi

# These are idempotent
sqlplus -S / as sysdba <<'SQL'
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM SET db_recovery_file_dest_size=10G;

-- Grant PDB user access to v$database for SCN queries in test scenarios
ALTER SESSION SET CONTAINER=XEPDB1;
GRANT SELECT ON SYS.V_$DATABASE TO olr_test;
SQL

# Signal that init is complete (used by healthcheck)
touch /tmp/olr_init_done

echo "01-setup.sh: Setup complete."
