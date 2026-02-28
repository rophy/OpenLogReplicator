-- rac-concurrent-tables.rac.sql: Each RAC node operates on a different table.
-- Tests OLR's multi-thread support when DML targets separate tables.

-- @SETUP
DECLARE
    v_table_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_RAC_TBL1';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_RAC_TBL1 PURGE';
    END IF;
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_RAC_TBL2';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_RAC_TBL2 PURGE';
    END IF;
END;
/

CREATE TABLE TEST_RAC_TBL1 (
    id   NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    val  NUMBER
);

CREATE TABLE TEST_RAC_TBL2 (
    id   NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    val  NUMBER
);

ALTER TABLE TEST_RAC_TBL1 ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
ALTER TABLE TEST_RAC_TBL2 ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

DECLARE
    v_start_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_start_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || v_start_scn);
END;
/

-- @NODE1
INSERT INTO TEST_RAC_TBL1 VALUES (1, 'T1-Alice', 100);
INSERT INTO TEST_RAC_TBL1 VALUES (2, 'T1-Bob', 200);
COMMIT;

-- @NODE2
INSERT INTO TEST_RAC_TBL2 VALUES (1, 'T2-Charlie', 300);
INSERT INTO TEST_RAC_TBL2 VALUES (2, 'T2-Diana', 400);
COMMIT;

-- @NODE1
UPDATE TEST_RAC_TBL1 SET val = 150 WHERE id = 1;
DELETE FROM TEST_RAC_TBL1 WHERE id = 2;
COMMIT;

-- @NODE2
UPDATE TEST_RAC_TBL2 SET val = 350 WHERE id = 1;
DELETE FROM TEST_RAC_TBL2 WHERE id = 2;
COMMIT;
