-- rac-thread2-only.rac.sql: All DML on node 2 (thread 2) only.
-- Tests OLR's ability to process redo from thread 2 in a RAC environment.

-- @SETUP
DECLARE
    v_table_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_RAC_T2';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_RAC_T2 PURGE';
    END IF;
END;
/

CREATE TABLE TEST_RAC_T2 (
    id   NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    val  NUMBER
);

ALTER TABLE TEST_RAC_T2 ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

DECLARE
    v_start_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_start_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || v_start_scn);
END;
/

-- @NODE2
INSERT INTO TEST_RAC_T2 VALUES (1, 'Thread2-Alice', 100);
INSERT INTO TEST_RAC_T2 VALUES (2, 'Thread2-Bob', 200);
INSERT INTO TEST_RAC_T2 VALUES (3, 'Thread2-Charlie', 300);
COMMIT;

-- @NODE2
UPDATE TEST_RAC_T2 SET val = 150, name = 'Thread2-Alice-Updated' WHERE id = 1;
COMMIT;

-- @NODE2
DELETE FROM TEST_RAC_T2 WHERE id = 3;
COMMIT;
