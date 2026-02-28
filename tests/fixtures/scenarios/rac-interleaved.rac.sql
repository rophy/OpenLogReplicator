-- rac-interleaved.rac.sql: Alternating DML on same table from both RAC nodes.
-- Tests OLR's ability to interleave and SCN-order transactions from multiple threads.

-- @SETUP
DECLARE
    v_table_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_table_exists
    FROM user_tables WHERE table_name = 'TEST_RAC_INTERLEAVE';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_RAC_INTERLEAVE PURGE';
    END IF;
END;
/

CREATE TABLE TEST_RAC_INTERLEAVE (
    id   NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    val  NUMBER
);

ALTER TABLE TEST_RAC_INTERLEAVE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

DECLARE
    v_start_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_start_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || v_start_scn);
END;
/

-- @NODE1
INSERT INTO TEST_RAC_INTERLEAVE VALUES (1, 'Node1-Alice', 100);
INSERT INTO TEST_RAC_INTERLEAVE VALUES (2, 'Node1-Bob', 200);
COMMIT;

-- @NODE2
INSERT INTO TEST_RAC_INTERLEAVE VALUES (3, 'Node2-Charlie', 300);
INSERT INTO TEST_RAC_INTERLEAVE VALUES (4, 'Node2-Diana', 400);
COMMIT;

-- @NODE1
UPDATE TEST_RAC_INTERLEAVE SET val = 150, name = 'Node1-Alice-Updated' WHERE id = 1;
COMMIT;

-- @NODE2
DELETE FROM TEST_RAC_INTERLEAVE WHERE id = 3;
COMMIT;
