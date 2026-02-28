-- boolean-type.sql: Oracle 23ai BOOLEAN column type.
-- Requires Oracle Database 23ai or later.
-- Run as PDB user (e.g., olr_test/olr_test@//host:1521/ORCLPDB)
--
-- Outputs: FIXTURE_SCN_START: <scn> and FIXTURE_SCN_END: <scn>

SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF

-- Setup: drop and recreate table
DECLARE
    v_table_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_BOOLEAN';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_BOOLEAN PURGE';
    END IF;
END;
/

CREATE TABLE TEST_BOOLEAN (
    id          NUMBER PRIMARY KEY,
    is_active   BOOLEAN,
    is_verified BOOLEAN,
    label       VARCHAR2(50)
);

ALTER TABLE TEST_BOOLEAN ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Record start SCN
DECLARE
    v_start_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_start_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || v_start_scn);
END;
/

-- INSERT: TRUE/FALSE
INSERT INTO TEST_BOOLEAN VALUES (1, TRUE, FALSE, 'true-false');
INSERT INTO TEST_BOOLEAN VALUES (2, FALSE, TRUE, 'false-true');
COMMIT;

-- INSERT: NULL booleans
INSERT INTO TEST_BOOLEAN VALUES (3, NULL, NULL, 'null-null');
COMMIT;

-- INSERT: both TRUE
INSERT INTO TEST_BOOLEAN VALUES (4, TRUE, TRUE, 'both-true');
COMMIT;

-- UPDATE: toggle values
UPDATE TEST_BOOLEAN SET is_active = FALSE, is_verified = TRUE WHERE id = 1;
COMMIT;

-- UPDATE: set to NULL
UPDATE TEST_BOOLEAN SET is_active = NULL WHERE id = 2;
COMMIT;

-- UPDATE: NULL to value
UPDATE TEST_BOOLEAN SET is_active = TRUE, is_verified = FALSE WHERE id = 3;
COMMIT;

-- DELETE
DELETE FROM TEST_BOOLEAN WHERE id = 4;
COMMIT;

-- Record end SCN
DECLARE
    v_end_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_end_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_END: ' || v_end_scn);
END;
/

EXIT
