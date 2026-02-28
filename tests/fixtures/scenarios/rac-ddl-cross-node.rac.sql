-- rac-ddl-cross-node.rac.sql: DDL on node 1, then DML on node 2 using the new schema.
-- Tests OLR's ability to detect schema change from thread 1's redo and apply it
-- when parsing thread 2's DML.
-- @DDL

-- @SETUP
DECLARE
    v_table_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_RAC_DDL';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_RAC_DDL PURGE';
    END IF;
END;
/

CREATE TABLE TEST_RAC_DDL (
    id   NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    val  NUMBER
);

ALTER TABLE TEST_RAC_DDL ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

DECLARE
    v_start_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_start_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || v_start_scn);
END;
/

-- @NODE1
-- Phase 1: DML with original schema (3 columns) on node 1
INSERT INTO TEST_RAC_DDL VALUES (1, 'Alice', 100);
INSERT INTO TEST_RAC_DDL VALUES (2, 'Bob', 200);
COMMIT;

-- DDL on node 1: add a new column
ALTER TABLE TEST_RAC_DDL ADD (email VARCHAR2(200));

-- @NODE2
-- Phase 2: DML with new schema (4 columns) on node 2
-- The DDL redo is only in thread 1, but node 2 sees the new schema
INSERT INTO TEST_RAC_DDL VALUES (3, 'Charlie', 300, 'charlie@test.com');
UPDATE TEST_RAC_DDL SET email = 'alice@test.com' WHERE id = 1;
COMMIT;

-- @NODE1
-- Phase 3: More DML on node 1 with new schema
UPDATE TEST_RAC_DDL SET val = 250, email = 'bob@test.com' WHERE id = 2;
DELETE FROM TEST_RAC_DDL WHERE id = 1;
COMMIT;
