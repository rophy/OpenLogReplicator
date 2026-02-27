-- basic-crud.sql: Simple INSERT/UPDATE/DELETE scenario for fixture generation.
-- Run as: sqlplus olr_test/olr_test@//host:1521/ORCLPDB @basic-crud.sql
--
-- Outputs: FIXTURE_SCN_RANGE: <start> - <end>
-- The orchestrator script parses this to know which SCN range to mine.

SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF

DECLARE
    v_start_scn NUMBER;
    v_end_scn NUMBER;
    v_table_exists NUMBER;
BEGIN
    -- Drop table if it already exists
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_CDC';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_CDC PURGE';
    END IF;

    -- Create test table
    EXECUTE IMMEDIATE '
        CREATE TABLE TEST_CDC (
            id   NUMBER PRIMARY KEY,
            name VARCHAR2(100),
            val  NUMBER
        )';

    -- Enable supplemental logging for all columns on this table
    EXECUTE IMMEDIATE 'ALTER TABLE TEST_CDC ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS';

    -- Record start SCN (before any DML)
    SELECT current_scn INTO v_start_scn FROM v$database;

    -- INSERT
    INSERT INTO TEST_CDC VALUES (1, 'Alice', 100);
    INSERT INTO TEST_CDC VALUES (2, 'Bob', 200);
    INSERT INTO TEST_CDC VALUES (3, 'Charlie', 300);
    COMMIT;

    -- UPDATE
    UPDATE TEST_CDC SET val = 150, name = 'Alice Updated' WHERE id = 1;
    COMMIT;

    -- DELETE
    DELETE FROM TEST_CDC WHERE id = 2;
    COMMIT;

    -- Force log switches to ensure redo is archived
    EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
    DBMS_SESSION.SLEEP(2);
    EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
    DBMS_SESSION.SLEEP(2);

    -- Record end SCN (after all DML and archival)
    SELECT current_scn INTO v_end_scn FROM v$database;

    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_RANGE: ' || v_start_scn || ' - ' || v_end_scn);
END;
/

EXIT
