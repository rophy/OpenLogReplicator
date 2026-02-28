-- ddl-changes.sql: Test DML interleaved with DDL (ALTER TABLE ADD/DROP COLUMN).
-- Run as PDB user (e.g., olr_test/olr_test@//host:1521/ORCLPDB)
--
-- Outputs: FIXTURE_SCN_START: <scn> and FIXTURE_SCN_END: <scn>
--
-- NOTE: OLR must handle schema evolution — the column set changes mid-stream.

SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET ECHO OFF

-- Setup: drop and recreate table
DECLARE
    v_table_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_DDL';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_DDL PURGE';
    END IF;
END;
/

CREATE TABLE TEST_DDL (
    id   NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    val  NUMBER
);

ALTER TABLE TEST_DDL ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Record start SCN
DECLARE
    v_start_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_start_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || v_start_scn);
END;
/

-- DML: initial inserts with original schema (id, name, val)
INSERT INTO TEST_DDL VALUES (1, 'before alter', 100);
INSERT INTO TEST_DDL VALUES (2, 'also before', 200);
COMMIT;

-- DDL: add a new column
ALTER TABLE TEST_DDL ADD (extra VARCHAR2(50));
ALTER TABLE TEST_DDL ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- DML: insert with new column present
INSERT INTO TEST_DDL VALUES (3, 'after add col', 300, 'extra data');
UPDATE TEST_DDL SET extra = 'backfilled' WHERE id = 1;
COMMIT;

-- DDL: add another column
ALTER TABLE TEST_DDL ADD (score NUMBER DEFAULT 0);
ALTER TABLE TEST_DDL ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- DML: use the newest schema
INSERT INTO TEST_DDL (id, name, val, extra, score) VALUES (4, 'all columns', 400, 'full', 95);
COMMIT;

-- DDL: drop a column
ALTER TABLE TEST_DDL DROP COLUMN extra;
ALTER TABLE TEST_DDL ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- DML: after column drop
INSERT INTO TEST_DDL (id, name, val, score) VALUES (5, 'after drop', 500, 80);
UPDATE TEST_DDL SET score = 50 WHERE id = 1;
COMMIT;

-- DML: delete
DELETE FROM TEST_DDL WHERE id = 2;
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
