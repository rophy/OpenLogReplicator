-- Setup for performance testing.
-- Creates the benchmark table and supplemental logging.

SET FEEDBACK OFF
SET SERVEROUTPUT ON

BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.PERF_BENCH PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/

CREATE TABLE olr_test.PERF_BENCH (
    id        NUMBER,
    val       VARCHAR2(200),
    node_id   NUMBER(1),
    batch_num NUMBER,
    created   TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT perf_bench_pk PRIMARY KEY (id, node_id)
);
ALTER TABLE olr_test.PERF_BENCH ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

DECLARE
    v_scn NUMBER;
BEGIN
    v_scn := DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER;
    DBMS_OUTPUT.PUT_LINE('PERF_SCN_START: ' || v_scn);
END;
/

EXIT
