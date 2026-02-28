-- logminer-extract.sql: Extract LogMiner data for a given SCN range.
-- Parameters (passed via SQL*Plus DEFINE):
--   &1 = start SCN
--   &2 = end SCN
--   &3 = output spool file path
--   &4 = schema owner (e.g., OLR_TEST)
--
-- Usage: sqlplus sys/oracle@//host:1521/ORCLPDB as sysdba @logminer-extract.sql 12345 67890 /tmp/logminer.out OLR_TEST

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

DEFINE start_scn = &1
DEFINE end_scn = &2
DEFINE outfile = &3
DEFINE schema_owner = &4

-- Add all archive logs that cover the SCN range
DECLARE
    v_count NUMBER := 0;
BEGIN
    FOR rec IN (
        SELECT name FROM v$archived_log
        WHERE first_change# <= &end_scn
          AND next_change# >= &start_scn
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
        DBMS_OUTPUT.PUT_LINE('ERROR: No archive logs found for SCN range &start_scn - &end_scn');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('Starting LogMiner with ' || v_count || ' log file(s)');

    DBMS_LOGMNR.START_LOGMNR(
        startScn => &start_scn,
        endScn   => &end_scn,
        options  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                  + DBMS_LOGMNR.NO_ROWID_IN_STMT
                  + DBMS_LOGMNR.COMMITTED_DATA_ONLY
    );
END;
/

-- Spool pipe-delimited output
SPOOL &outfile

SELECT TO_CLOB(scn || '|' || operation || '|' || seg_owner || '|' || table_name || '|' || xid || '|') ||
       REPLACE(REPLACE(sql_redo, CHR(10), ' '), CHR(13), '') || '|' ||
       REPLACE(REPLACE(NVL(sql_undo, ''), CHR(10), ' '), CHR(13), '')
FROM v$logmnr_contents
WHERE seg_owner = UPPER('&schema_owner')
  AND operation IN ('INSERT', 'UPDATE', 'DELETE')
ORDER BY scn, xid, sequence#;

SPOOL OFF

-- End LogMiner session
BEGIN
    DBMS_LOGMNR.END_LOGMNR;
END;
/

EXIT
