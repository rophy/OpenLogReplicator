-- @TAG us7ascii
-- multibyte-passthrough.sql: Test multi-byte characters stored as pass-through
-- in a non-UTF8 database (e.g., US7ASCII).
-- Run as PDB user (e.g., olr_test/olr_test@//localhost:1521/XEPDB1)
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
    FROM user_tables WHERE table_name = 'TEST_MULTIBYTE';
    IF v_table_exists > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE TEST_MULTIBYTE PURGE';
    END IF;
END;
/

CREATE TABLE TEST_MULTIBYTE (
    id    NUMBER PRIMARY KEY,
    name  VARCHAR2(200),
    note  VARCHAR2(400)
);

ALTER TABLE TEST_MULTIBYTE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Record start SCN
DECLARE
    v_start_scn NUMBER;
BEGIN
    SELECT current_scn INTO v_start_scn FROM v$database;
    DBMS_OUTPUT.PUT_LINE('FIXTURE_SCN_START: ' || v_start_scn);
END;
/

-- Insert Big5 Chinese characters as raw bytes (pass-through in US7ASCII DB)
-- Big5: 台北=A578A55F  台灣首都=A578C657ADBAB3A3
-- 你好世界=A741A66EA540ACC9  測試資料=B4FAB8D5B8EAAEC6
-- 更新完成=A7F3B773A7B9A6A8
INSERT INTO TEST_MULTIBYTE VALUES (1,
    UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('A578A55F')),
    UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('A578C657ADBAB3A3')));
INSERT INTO TEST_MULTIBYTE VALUES (2,
    UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('A741A66EA540ACC9')),
    'Hello World');
INSERT INTO TEST_MULTIBYTE VALUES (3,
    UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('B4FAB8D5B8EAAEC6')),
    'test data');
COMMIT;

-- Update with mixed ASCII + Big5: "updated: " + 更新完成(A7F3B773A7B9A6A8)
UPDATE TEST_MULTIBYTE SET note =
    'updated: ' || UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('A7F3B773A7B9A6A8'))
    WHERE id = 1;
COMMIT;

-- Delete
DELETE FROM TEST_MULTIBYTE WHERE id = 2;
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
