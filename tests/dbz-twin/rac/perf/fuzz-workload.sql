-- fuzz-workload.sql — Randomized DML generator for OLR fuzz testing.
--
-- Creates diverse tables + a PL/SQL package that generates random DML
-- exercising CDC edge cases: LOBs, wide rows, partitions, rollbacks,
-- savepoints, bulk inserts, NULLs, and varied data types.
--
-- Every table has an EVENT_ID column (VARCHAR2(30)) that uniquely identifies
-- each CDC event. Format: N{node}_{table_prefix}_{seq:06d}
-- This enables streaming comparison without ordering assumptions.
--
-- Usage:
--   1. Run this file once to create schema + package:
--      sqlplus olr_test/olr_test@... @fuzz-workload.sql
--
--   2. Run the workload (from shell, per node):
--      sqlplus olr_test/olr_test@... <<< "SET SERVEROUTPUT ON SIZE UNLIMITED
--      EXEC FUZZ_WKL.run(p_duration_secs => 300, p_seed => 42, p_node_id => 1);
--      EXIT;"

SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

-- ============================================================
-- Section 1: Create tables (idempotent via DROP IF EXISTS)
-- ============================================================

-- T1: Core scalar types
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_SCALAR PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_SCALAR (
    id           NUMBER PRIMARY KEY,
    event_id     VARCHAR2(30) NOT NULL,
    col_varchar  VARCHAR2(200),
    col_char     CHAR(20),
    col_number   NUMBER,
    col_int      NUMBER(10),
    col_decimal  NUMBER(20,10),
    col_float    BINARY_FLOAT,
    col_double   BINARY_DOUBLE,
    col_date     DATE,
    col_ts       TIMESTAMP(6),
    col_raw      RAW(200),
    col_flag     NUMBER(1) DEFAULT 0
);
ALTER TABLE olr_test.FUZZ_SCALAR ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- T2: Wide row (40+ columns)
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_WIDE PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_WIDE (
    id   NUMBER PRIMARY KEY,
    event_id VARCHAR2(30) NOT NULL,
    c01  VARCHAR2(100), c02  VARCHAR2(100), c03  VARCHAR2(100), c04  VARCHAR2(100), c05  VARCHAR2(100),
    c06  VARCHAR2(100), c07  VARCHAR2(100), c08  VARCHAR2(100), c09  VARCHAR2(100), c10  VARCHAR2(100),
    c11  VARCHAR2(100), c12  VARCHAR2(100), c13  VARCHAR2(100), c14  VARCHAR2(100), c15  VARCHAR2(100),
    n01  NUMBER, n02  NUMBER, n03  NUMBER, n04  NUMBER, n05  NUMBER,
    n06  NUMBER, n07  NUMBER, n08  NUMBER, n09  NUMBER, n10  NUMBER,
    d01  DATE, d02  DATE, d03  DATE,
    t01  TIMESTAMP, t02  TIMESTAMP, t03  TIMESTAMP,
    r01  RAW(50), r02  RAW(50), r03  RAW(50)
);
ALTER TABLE olr_test.FUZZ_WIDE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- T3: LOB table (CLOB + BLOB)
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_LOB PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_LOB (
    id       NUMBER PRIMARY KEY,
    event_id VARCHAR2(30) NOT NULL,
    label    VARCHAR2(50),
    content  CLOB,
    bin_data BLOB
);
ALTER TABLE olr_test.FUZZ_LOB ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- T4: Partitioned table
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_PART PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_PART (
    id       NUMBER PRIMARY KEY,
    event_id VARCHAR2(30) NOT NULL,
    region   VARCHAR2(20),
    val      NUMBER,
    payload  VARCHAR2(500)
) PARTITION BY LIST (region) (
    PARTITION p_east  VALUES ('EAST'),
    PARTITION p_west  VALUES ('WEST'),
    PARTITION p_north VALUES ('NORTH'),
    PARTITION p_south VALUES ('SOUTH'),
    PARTITION p_other VALUES (DEFAULT)
);
ALTER TABLE olr_test.FUZZ_PART ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- T5: No primary key (forces ROWID-based supplemental logging)
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_NOPK PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_NOPK (
    event_id VARCHAR2(30) NOT NULL,
    name     VARCHAR2(100),
    value    NUMBER,
    status   VARCHAR2(20),
    ts       TIMESTAMP DEFAULT SYSTIMESTAMP
);
ALTER TABLE olr_test.FUZZ_NOPK ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- T6: Max-length strings (near block boundary)
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_MAXSTR PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_MAXSTR (
    id        NUMBER PRIMARY KEY,
    event_id  VARCHAR2(30) NOT NULL,
    col_long1 VARCHAR2(4000),
    col_long2 VARCHAR2(4000),
    col_short VARCHAR2(10)
);
ALTER TABLE olr_test.FUZZ_MAXSTR ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- T7: Interval types
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_INTERVAL PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_INTERVAL (
    id      NUMBER PRIMARY KEY,
    event_id VARCHAR2(30) NOT NULL,
    col_ym  INTERVAL YEAR(4) TO MONTH,
    col_ds  INTERVAL DAY(4) TO SECOND(6),
    col_num NUMBER
);
ALTER TABLE olr_test.FUZZ_INTERVAL ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Stats table (autonomous transaction writes, polled by shell)
BEGIN EXECUTE IMMEDIATE 'DROP TABLE olr_test.FUZZ_STATS PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
CREATE TABLE olr_test.FUZZ_STATS (
    node_id      NUMBER PRIMARY KEY,
    total_ops    NUMBER DEFAULT 0,
    insert_cnt   NUMBER DEFAULT 0,
    update_cnt   NUMBER DEFAULT 0,
    delete_cnt   NUMBER DEFAULT 0,
    rollback_cnt NUMBER DEFAULT 0,
    lob_cnt      NUMBER DEFAULT 0,
    last_update  TIMESTAMP DEFAULT SYSTIMESTAMP
);

-- ============================================================
-- Section 2: Package specification
-- ============================================================

CREATE OR REPLACE PACKAGE olr_test.FUZZ_WKL AS
    PROCEDURE run(
        p_duration_secs IN NUMBER DEFAULT 1800,
        p_seed          IN NUMBER DEFAULT 1,
        p_node_id       IN NUMBER DEFAULT 1,
        p_skip_lob      IN NUMBER DEFAULT 0   -- 1 = skip LOB table operations
    );
END FUZZ_WKL;
/

-- ============================================================
-- Section 3: Package body
-- ============================================================

CREATE OR REPLACE PACKAGE BODY olr_test.FUZZ_WKL AS

    -- Per-session state
    g_node_id    PLS_INTEGER;
    g_next_id    PLS_INTEGER;  -- node 1: odd (1,3,5...), node 2: even (2,4,6...)
    g_event_seq  PLS_INTEGER := 0;
    g_insert_cnt PLS_INTEGER := 0;
    g_update_cnt PLS_INTEGER := 0;
    g_delete_cnt PLS_INTEGER := 0;
    g_rollback_cnt PLS_INTEGER := 0;
    g_lob_cnt    PLS_INTEGER := 0;
    g_total_ops  PLS_INTEGER := 0;
    g_skip_lob   PLS_INTEGER := 0;  -- 1 = skip LOB table operations

    -- Per-table ID tracking for UPDATE/DELETE targeting.
    -- Stores the last inserted ID for each table so UPDATE/DELETE can
    -- pick from the correct table's ID range instead of the global stream.
    TYPE id_list_t IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    g_scalar_ids id_list_t;
    g_scalar_id_cnt PLS_INTEGER := 0;
    g_lob_ids    id_list_t;
    g_lob_id_cnt PLS_INTEGER := 0;
    g_wide_ids   id_list_t;
    g_wide_id_cnt PLS_INTEGER := 0;
    g_part_ids   id_list_t;
    g_part_id_cnt PLS_INTEGER := 0;
    g_maxstr_ids id_list_t;
    g_maxstr_id_cnt PLS_INTEGER := 0;
    g_interval_ids id_list_t;
    g_interval_id_cnt PLS_INTEGER := 0;

    REGIONS CONSTANT SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST(
        'EAST','WEST','NORTH','SOUTH','OTHER');

    -- ---- Helpers ----

    FUNCTION next_id RETURN PLS_INTEGER IS
        v_id PLS_INTEGER;
    BEGIN
        v_id := g_next_id;
        g_next_id := g_next_id + 2;  -- skip by 2 for node interleaving
        RETURN v_id;
    END;

    FUNCTION next_event_id RETURN VARCHAR2 IS
    BEGIN
        g_event_seq := g_event_seq + 1;
        RETURN 'N' || g_node_id || '_' || LPAD(g_event_seq, 8, '0');
    END;

    FUNCTION rand_int(p_lo PLS_INTEGER, p_hi PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN
        RETURN TRUNC(DBMS_RANDOM.VALUE(p_lo, p_hi + 1));
    END;

    FUNCTION rand_varchar(p_max_len PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_RANDOM.STRING('p', rand_int(1, p_max_len));
    END;

    FUNCTION rand_date RETURN DATE IS
    BEGIN
        RETURN SYSDATE - TRUNC(DBMS_RANDOM.VALUE(0, 9000));
    END;

    FUNCTION rand_raw(p_max_len PLS_INTEGER) RETURN RAW IS
    BEGIN
        RETURN UTL_RAW.CAST_TO_RAW(DBMS_RANDOM.STRING('x', rand_int(1, LEAST(p_max_len, 100))));
    END;

    FUNCTION rand_region RETURN VARCHAR2 IS
    BEGIN
        RETURN REGIONS(rand_int(1, 5));
    END;

    -- Track an inserted ID for a table
    PROCEDURE track_id(p_ids IN OUT id_list_t, p_cnt IN OUT PLS_INTEGER, p_id PLS_INTEGER) IS
    BEGIN
        p_cnt := p_cnt + 1;
        p_ids(p_cnt) := p_id;
    END;

    -- Pick a random tracked ID for UPDATE/DELETE. Returns -1 if no IDs tracked.
    FUNCTION pick_tracked_id(p_ids IN id_list_t, p_cnt PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN
        IF p_cnt = 0 THEN RETURN -1; END IF;
        RETURN p_ids(rand_int(1, p_cnt));
    END;

    PROCEDURE update_stats IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        MERGE INTO olr_test.FUZZ_STATS s USING (SELECT g_node_id AS nid FROM dual) d
        ON (s.node_id = d.nid)
        WHEN MATCHED THEN UPDATE SET
            total_ops = g_total_ops, insert_cnt = g_insert_cnt,
            update_cnt = g_update_cnt, delete_cnt = g_delete_cnt,
            rollback_cnt = g_rollback_cnt, lob_cnt = g_lob_cnt,
            last_update = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (node_id, total_ops, insert_cnt, update_cnt,
            delete_cnt, rollback_cnt, lob_cnt, last_update)
            VALUES (g_node_id, g_total_ops, g_insert_cnt, g_update_cnt,
                    g_delete_cnt, g_rollback_cnt, g_lob_cnt, SYSTIMESTAMP);
        COMMIT;
    END;

    -- ---- DML operations ----
    -- Note: PL/SQL package-private functions cannot be called directly in SQL
    -- statements, so all random values are computed into local variables first.

    PROCEDURE do_insert_scalar(p_count PLS_INTEGER) IS
        v_id PLS_INTEGER; v_eid VARCHAR2(30);
        v_vc VARCHAR2(200); v_ch CHAR(20); v_num NUMBER;
        v_int NUMBER(10); v_dec NUMBER(20,10); v_fl BINARY_FLOAT;
        v_dbl BINARY_DOUBLE; v_dt DATE; v_ts TIMESTAMP(6);
        v_rw RAW(200); v_flag NUMBER(1);
    BEGIN
        FOR i IN 1..p_count LOOP
            v_id := next_id; v_eid := next_event_id;
            v_vc := rand_varchar(200);
            v_ch := RPAD(DBMS_RANDOM.STRING('a', rand_int(1,10)), 20);
            v_num := ROUND(DBMS_RANDOM.VALUE(-1e15, 1e15), rand_int(0,10));
            v_int := TRUNC(DBMS_RANDOM.VALUE(-2147483648, 2147483647));
            v_dec := ROUND(DBMS_RANDOM.VALUE(-99999, 99999), 10);
            v_fl := CAST(DBMS_RANDOM.VALUE(-1e10, 1e10) AS BINARY_FLOAT);
            v_dbl := CAST(DBMS_RANDOM.VALUE(-1e100, 1e100) AS BINARY_DOUBLE);
            v_dt := rand_date; v_ts := SYSTIMESTAMP - DBMS_RANDOM.VALUE(0, 1000);
            v_rw := rand_raw(100); v_flag := rand_int(0,1);
            INSERT INTO olr_test.FUZZ_SCALAR (id, event_id, col_varchar, col_char, col_number,
                col_int, col_decimal, col_float, col_double, col_date, col_ts, col_raw, col_flag)
            VALUES (v_id, v_eid, v_vc, v_ch, v_num, v_int, v_dec, v_fl, v_dbl, v_dt, v_ts, v_rw, v_flag);
            track_id(g_scalar_ids, g_scalar_id_cnt, v_id);
            g_insert_cnt := g_insert_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_insert_wide(p_count PLS_INTEGER) IS
        v_id PLS_INTEGER; v_eid VARCHAR2(30);
        v_c01 VARCHAR2(100); v_c02 VARCHAR2(100); v_c03 VARCHAR2(100);
        v_c04 VARCHAR2(100); v_c05 VARCHAR2(100); v_c06 VARCHAR2(100);
        v_c07 VARCHAR2(100); v_c08 VARCHAR2(100); v_c09 VARCHAR2(100);
        v_c10 VARCHAR2(100); v_c11 VARCHAR2(100); v_c12 VARCHAR2(100);
        v_c13 VARCHAR2(100); v_c14 VARCHAR2(100); v_c15 VARCHAR2(100);
        v_d1 DATE; v_d2 DATE; v_d3 DATE;
        v_r1 RAW(50); v_r2 RAW(50); v_r3 RAW(50);
    BEGIN
        FOR i IN 1..p_count LOOP
            v_id := next_id; v_eid := next_event_id;
            v_c01:=rand_varchar(100); v_c02:=rand_varchar(100); v_c03:=rand_varchar(100);
            v_c04:=rand_varchar(100); v_c05:=rand_varchar(100); v_c06:=rand_varchar(100);
            v_c07:=rand_varchar(100); v_c08:=rand_varchar(100); v_c09:=rand_varchar(100);
            v_c10:=rand_varchar(100); v_c11:=rand_varchar(100); v_c12:=rand_varchar(100);
            v_c13:=rand_varchar(100); v_c14:=rand_varchar(100); v_c15:=rand_varchar(100);
            v_d1:=rand_date; v_d2:=rand_date; v_d3:=rand_date;
            v_r1:=rand_raw(50); v_r2:=rand_raw(50); v_r3:=rand_raw(50);
            INSERT INTO olr_test.FUZZ_WIDE (id, event_id,
                c01,c02,c03,c04,c05,c06,c07,c08,c09,c10,c11,c12,c13,c14,c15,
                n01,n02,n03,n04,n05,n06,n07,n08,n09,n10,
                d01,d02,d03, t01,t02,t03, r01,r02,r03)
            VALUES (v_id, v_eid,
                v_c01,v_c02,v_c03,v_c04,v_c05,v_c06,v_c07,v_c08,v_c09,v_c10,
                v_c11,v_c12,v_c13,v_c14,v_c15,
                DBMS_RANDOM.VALUE(-1e12,1e12),DBMS_RANDOM.VALUE(-1e12,1e12),
                DBMS_RANDOM.VALUE(-1e12,1e12),DBMS_RANDOM.VALUE(-1e12,1e12),
                DBMS_RANDOM.VALUE(-1e12,1e12),DBMS_RANDOM.VALUE(-1e12,1e12),
                DBMS_RANDOM.VALUE(-1e12,1e12),DBMS_RANDOM.VALUE(-1e12,1e12),
                DBMS_RANDOM.VALUE(-1e12,1e12),DBMS_RANDOM.VALUE(-1e12,1e12),
                v_d1,v_d2,v_d3,
                SYSTIMESTAMP-DBMS_RANDOM.VALUE(0,500),
                SYSTIMESTAMP-DBMS_RANDOM.VALUE(0,500),
                SYSTIMESTAMP-DBMS_RANDOM.VALUE(0,500),
                v_r1,v_r2,v_r3);
            track_id(g_wide_ids, g_wide_id_cnt, v_id);
            g_insert_cnt := g_insert_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_insert_lob(p_count PLS_INTEGER) IS
        v_id PLS_INTEGER; v_eid VARCHAR2(30);
        v_clob_size PLS_INTEGER; v_blob_size PLS_INTEGER;
        v_label VARCHAR2(50); v_clob CLOB; v_blob BLOB;
    BEGIN
        FOR i IN 1..p_count LOOP
            v_id := next_id; v_eid := next_event_id;
            v_clob_size := rand_int(50, 16000);
            v_blob_size := rand_int(50, 8000);
            v_label := 'lob_n' || g_node_id || '_' || g_total_ops;
            v_clob := RPAD(DBMS_RANDOM.STRING('x', 50), v_clob_size, 'X');
            v_blob := UTL_RAW.COPIES(UTL_RAW.CAST_TO_RAW(DBMS_RANDOM.STRING('x', 10)),
                                     LEAST(CEIL(v_blob_size / 10), 800));
            INSERT INTO olr_test.FUZZ_LOB (id, event_id, label, content, bin_data)
            VALUES (v_id, v_eid, v_label, v_clob, v_blob);
            track_id(g_lob_ids, g_lob_id_cnt, v_id);
            g_insert_cnt := g_insert_cnt + 1;
            g_lob_cnt := g_lob_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_insert_part(p_count PLS_INTEGER) IS
        v_id PLS_INTEGER; v_eid VARCHAR2(30);
        v_region VARCHAR2(20); v_payload VARCHAR2(500);
    BEGIN
        FOR i IN 1..p_count LOOP
            v_id := next_id; v_eid := next_event_id;
            v_region := rand_region; v_payload := rand_varchar(500);
            INSERT INTO olr_test.FUZZ_PART (id, event_id, region, val, payload)
            VALUES (v_id, v_eid, v_region, ROUND(DBMS_RANDOM.VALUE(-99999, 99999), 2), v_payload);
            track_id(g_part_ids, g_part_id_cnt, v_id);
            g_insert_cnt := g_insert_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_insert_nopk(p_count PLS_INTEGER) IS
        v_eid VARCHAR2(30); v_name VARCHAR2(100); v_status VARCHAR2(20);
    BEGIN
        FOR i IN 1..p_count LOOP
            v_eid := next_event_id;
            v_name := rand_varchar(100);
            v_status := CASE rand_int(1,4) WHEN 1 THEN 'ACTIVE' WHEN 2 THEN 'INACTIVE'
                         WHEN 3 THEN 'PENDING' ELSE NULL END;
            INSERT INTO olr_test.FUZZ_NOPK (event_id, name, value, status)
            VALUES (v_eid, v_name, ROUND(DBMS_RANDOM.VALUE(0, 100000), 2), v_status);
            g_insert_cnt := g_insert_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_insert_maxstr(p_count PLS_INTEGER) IS
        v_id PLS_INTEGER; v_eid VARCHAR2(30);
        v_l1 VARCHAR2(4000); v_l2 VARCHAR2(4000);
        v_sh VARCHAR2(10); v_len1 PLS_INTEGER; v_len2 PLS_INTEGER;
    BEGIN
        FOR i IN 1..p_count LOOP
            v_id := next_id; v_eid := next_event_id;
            v_len1 := rand_int(100, 4000); v_len2 := rand_int(100, 4000);
            v_l1 := RPAD('A', v_len1, DBMS_RANDOM.STRING('x', 1));
            v_l2 := RPAD('B', v_len2, DBMS_RANDOM.STRING('x', 1));
            v_sh := DBMS_RANDOM.STRING('x', rand_int(1,10));
            INSERT INTO olr_test.FUZZ_MAXSTR (id, event_id, col_long1, col_long2, col_short)
            VALUES (v_id, v_eid, v_l1, v_l2, v_sh);
            track_id(g_maxstr_ids, g_maxstr_id_cnt, v_id);
            g_insert_cnt := g_insert_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_insert_interval(p_count PLS_INTEGER) IS
        v_id PLS_INTEGER; v_eid VARCHAR2(30); v_ym PLS_INTEGER;
    BEGIN
        FOR i IN 1..p_count LOOP
            v_id := next_id; v_eid := next_event_id;
            v_ym := rand_int(-100, 100);
            INSERT INTO olr_test.FUZZ_INTERVAL (id, event_id, col_ym, col_ds, col_num)
            VALUES (v_id, v_eid,
                NUMTOYMINTERVAL(v_ym, 'MONTH'),
                NUMTODSINTERVAL(DBMS_RANDOM.VALUE(-86400*100, 86400*100), 'SECOND'),
                ROUND(DBMS_RANDOM.VALUE(-1e8, 1e8), 4));
            track_id(g_interval_ids, g_interval_id_cnt, v_id);
            g_insert_cnt := g_insert_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    -- Update random rows in FUZZ_SCALAR (uses tracked IDs for this table)
    PROCEDURE do_update_scalar(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER;
        v_vc VARCHAR2(200); v_dt DATE;
    BEGIN
        IF g_scalar_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_scalar_ids, g_scalar_id_cnt);
            v_vc := rand_varchar(200); v_dt := rand_date;
            UPDATE olr_test.FUZZ_SCALAR
            SET col_varchar = v_vc,
                col_number = ROUND(DBMS_RANDOM.VALUE(-1e12, 1e12), TRUNC(DBMS_RANDOM.VALUE(0,9))),
                col_date = v_dt,
                col_flag = 1 - col_flag
            WHERE id = v_target;
            g_update_cnt := g_update_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    -- Delete random rows from FUZZ_SCALAR
    -- The before-image carries the existing event_id from the last INSERT/UPDATE.
    -- The consumer extracts event_id from 'before' for DELETE ops.
    PROCEDURE do_delete_scalar(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER;
    BEGIN
        IF g_scalar_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_scalar_ids, g_scalar_id_cnt);
            DELETE FROM olr_test.FUZZ_SCALAR WHERE id = v_target;
            g_delete_cnt := g_delete_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    -- Update LOB content
    PROCEDURE do_update_lob(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER;
        v_content CLOB; v_label VARCHAR2(50);
    BEGIN
        IF g_lob_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_lob_ids, g_lob_id_cnt);
            v_content := RPAD('UPD_', rand_int(100, 8000), 'Y');
            v_label := 'upd_n' || g_node_id || '_' || g_total_ops;
            UPDATE olr_test.FUZZ_LOB
            SET content = v_content, label = v_label
            WHERE id = v_target;
            g_update_cnt := g_update_cnt + 1;
            g_lob_cnt := g_lob_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    -- Bulk insert via FORALL
    PROCEDURE do_bulk_insert_scalar(p_count PLS_INTEGER) IS
        TYPE id_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        TYPE str_tab IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
        TYPE eid_tab IS TABLE OF VARCHAR2(30) INDEX BY PLS_INTEGER;
        TYPE num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        v_ids id_tab;
        v_eids eid_tab;
        v_vals str_tab;
        v_nums num_tab;
    BEGIN
        FOR i IN 1..p_count LOOP
            v_ids(i) := next_id;
            v_eids(i) := next_event_id;
            v_vals(i) := rand_varchar(100);
            v_nums(i) := ROUND(DBMS_RANDOM.VALUE(-99999, 99999), 2);
        END LOOP;
        FORALL i IN 1..p_count
            INSERT INTO olr_test.FUZZ_SCALAR (id, event_id, col_varchar, col_number, col_flag)
            VALUES (v_ids(i), v_eids(i), v_vals(i), v_nums(i), 0);
        FOR i IN 1..p_count LOOP
            track_id(g_scalar_ids, g_scalar_id_cnt, v_ids(i));
        END LOOP;
        g_insert_cnt := g_insert_cnt + p_count;
        g_total_ops := g_total_ops + p_count;
    END;

    -- Insert with many NULLs (tests NULL/absent column redo format)
    PROCEDURE do_insert_nulls(p_count PLS_INTEGER) IS
        v_id PLS_INTEGER; v_eid VARCHAR2(30);
        v_vc VARCHAR2(50); v_ch CHAR(20); v_num NUMBER;
        v_int PLS_INTEGER; v_dec NUMBER; v_fl BINARY_FLOAT; v_dbl BINARY_DOUBLE;
        v_dt DATE; v_ts TIMESTAMP; v_rw RAW(50); v_flag NUMBER(1);
    BEGIN
        FOR i IN 1..p_count LOOP
            v_id := next_id; v_eid := next_event_id;
            v_vc := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE rand_varchar(50) END;
            v_ch := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE RPAD('x', 20) END;
            v_num := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE DBMS_RANDOM.VALUE(-100,100) END;
            v_int := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE rand_int(-1000,1000) END;
            v_dec := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE ROUND(DBMS_RANDOM.VALUE(-99,99),10) END;
            v_fl := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE CAST(1.5 AS BINARY_FLOAT) END;
            v_dbl := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE CAST(2.5 AS BINARY_DOUBLE) END;
            v_dt := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE rand_date END;
            v_ts := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE SYSTIMESTAMP END;
            v_rw := CASE WHEN DBMS_RANDOM.VALUE < 0.5 THEN NULL ELSE rand_raw(50) END;
            v_flag := rand_int(0,1);
            INSERT INTO olr_test.FUZZ_SCALAR (id, event_id, col_varchar, col_char, col_number,
                col_int, col_decimal, col_float, col_double, col_date, col_ts, col_raw, col_flag)
            VALUES (v_id, v_eid, v_vc, v_ch, v_num, v_int, v_dec, v_fl, v_dbl, v_dt, v_ts, v_rw, v_flag);
            track_id(g_scalar_ids, g_scalar_id_cnt, v_id);
            g_insert_cnt := g_insert_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    -- ---- UPDATE/DELETE for edge-case tables ----

    PROCEDURE do_update_wide(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER;
        v_c1 VARCHAR2(100); v_c2 VARCHAR2(100); v_d DATE;
    BEGIN
        IF g_wide_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_wide_ids, g_wide_id_cnt);
            v_c1 := rand_varchar(100); v_c2 := rand_varchar(100); v_d := rand_date;
            UPDATE olr_test.FUZZ_WIDE
            SET c01 = v_c1, c02 = v_c2,
                n01 = DBMS_RANDOM.VALUE(-1e12, 1e12),
                d01 = v_d
            WHERE id = v_target;
            g_update_cnt := g_update_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_delete_wide(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER;
    BEGIN
        IF g_wide_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_wide_ids, g_wide_id_cnt);
            DELETE FROM olr_test.FUZZ_WIDE WHERE id = v_target;
            g_delete_cnt := g_delete_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_update_part(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER; v_payload VARCHAR2(500);
    BEGIN
        IF g_part_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_part_ids, g_part_id_cnt);
            v_payload := rand_varchar(500);
            UPDATE olr_test.FUZZ_PART
            SET val = ROUND(DBMS_RANDOM.VALUE(-99999, 99999), 2),
                payload = v_payload
            WHERE id = v_target;
            g_update_cnt := g_update_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_delete_part(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER;
    BEGIN
        IF g_part_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_part_ids, g_part_id_cnt);
            DELETE FROM olr_test.FUZZ_PART WHERE id = v_target;
            g_delete_cnt := g_delete_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_update_maxstr(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER;
        v_l1 VARCHAR2(4000); v_l2 VARCHAR2(4000);
        v_len1 PLS_INTEGER; v_len2 PLS_INTEGER;
    BEGIN
        IF g_maxstr_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_maxstr_ids, g_maxstr_id_cnt);
            v_len1 := rand_int(100, 4000); v_len2 := rand_int(100, 4000);
            v_l1 := RPAD('U', v_len1, DBMS_RANDOM.STRING('x', 1));
            v_l2 := RPAD('U', v_len2, DBMS_RANDOM.STRING('x', 1));
            UPDATE olr_test.FUZZ_MAXSTR
            SET col_long1 = v_l1, col_long2 = v_l2
            WHERE id = v_target;
            g_update_cnt := g_update_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    PROCEDURE do_update_interval(p_count PLS_INTEGER) IS
        v_target PLS_INTEGER; v_ym PLS_INTEGER;
    BEGIN
        IF g_interval_id_cnt = 0 THEN RETURN; END IF;
        FOR i IN 1..p_count LOOP
            v_target := pick_tracked_id(g_interval_ids, g_interval_id_cnt);
            v_ym := rand_int(-100, 100);
            UPDATE olr_test.FUZZ_INTERVAL
            SET col_ym = NUMTOYMINTERVAL(v_ym, 'MONTH'),
                col_num = ROUND(DBMS_RANDOM.VALUE(-1e8, 1e8), 4)
            WHERE id = v_target;
            g_update_cnt := g_update_cnt + 1;
            g_total_ops := g_total_ops + 1;
        END LOOP;
    END;

    -- ---- Dispatch: pick table + operation ----

    PROCEDURE do_random_op IS
        v_table_dice PLS_INTEGER := rand_int(1, 100);
        v_op_dice    PLS_INTEGER := rand_int(1, 100);
        v_count      PLS_INTEGER;
    BEGIN
        -- Pick table (weighted)
        -- With LOB:    30% scalar, 10% wide, 15% lob, 10% part, 10% nopk, 10% maxstr, 5% interval, 10% null
        -- Without LOB: 35% scalar, 12% wide, 0% lob, 12% part, 12% nopk, 12% maxstr, 7% interval, 10% null
        -- When g_skip_lob=1, remap the 15% LOB range to other tables
        IF g_skip_lob = 1 AND v_table_dice > 40 AND v_table_dice <= 55 THEN
            -- Remap LOB range (41-55) to scalar
            v_table_dice := rand_int(1, 30);
        END IF;
        IF v_table_dice <= 30 THEN
            -- FUZZ_SCALAR
            v_count := rand_int(1, 20);
            IF v_op_dice <= 50 THEN
                do_insert_scalar(v_count);
            ELSIF v_op_dice <= 75 THEN
                do_update_scalar(v_count);
            ELSIF v_op_dice <= 90 THEN
                do_delete_scalar(v_count);
            ELSE
                do_bulk_insert_scalar(rand_int(20, 50));
            END IF;
        ELSIF v_table_dice <= 40 THEN
            -- FUZZ_WIDE
            v_count := rand_int(1, 10);
            IF v_op_dice <= 60 THEN
                do_insert_wide(v_count);
            ELSIF v_op_dice <= 85 THEN
                do_update_wide(v_count);
            ELSE
                do_delete_wide(v_count);
            END IF;
        ELSIF v_table_dice <= 55 THEN
            -- LOB
            v_count := rand_int(1, 5);
            IF v_op_dice <= 60 THEN
                do_insert_lob(v_count);
            ELSE
                do_update_lob(v_count);
            END IF;
        ELSIF v_table_dice <= 65 THEN
            -- FUZZ_PART
            v_count := rand_int(1, 20);
            IF v_op_dice <= 60 THEN
                do_insert_part(v_count);
            ELSIF v_op_dice <= 85 THEN
                do_update_part(v_count);
            ELSE
                do_delete_part(v_count);
            END IF;
        ELSIF v_table_dice <= 75 THEN
            do_insert_nopk(rand_int(1, 15));
        ELSIF v_table_dice <= 85 THEN
            -- FUZZ_MAXSTR
            v_count := rand_int(1, 5);
            IF v_op_dice <= 65 THEN
                do_insert_maxstr(v_count);
            ELSE
                do_update_maxstr(v_count);
            END IF;
        ELSIF v_table_dice <= 90 THEN
            -- FUZZ_INTERVAL
            v_count := rand_int(1, 10);
            IF v_op_dice <= 65 THEN
                do_insert_interval(v_count);
            ELSE
                do_update_interval(v_count);
            END IF;
        ELSE
            do_insert_nulls(rand_int(1, 15));
        END IF;
    END;

    -- ---- Main entry point ----

    PROCEDURE run(
        p_duration_secs IN NUMBER DEFAULT 1800,
        p_seed          IN NUMBER DEFAULT 1,
        p_node_id       IN NUMBER DEFAULT 1,
        p_skip_lob      IN NUMBER DEFAULT 0
    ) IS
        v_start     TIMESTAMP := SYSTIMESTAMP;
        v_deadline  TIMESTAMP := SYSTIMESTAMP + NUMTODSINTERVAL(p_duration_secs, 'SECOND');
        v_txn_dice  PLS_INTEGER;
        v_batch     PLS_INTEGER;
        v_seed_id   PLS_INTEGER;
        v_seed_region VARCHAR2(20);
    BEGIN
        -- Initialize
        g_node_id := p_node_id;
        g_next_id := p_node_id;  -- 1 for node 1 (odd), 2 for node 2 (even)
        g_event_seq := 0;
        g_insert_cnt := 0; g_update_cnt := 0; g_delete_cnt := 0;
        g_rollback_cnt := 0; g_lob_cnt := 0; g_total_ops := 0;
        g_skip_lob := p_skip_lob;

        DBMS_RANDOM.SEED(p_seed);

        -- Seed initial data (need rows before we can UPDATE/DELETE).
        -- event_id='SEED' so the consumer skips these (they may arrive
        -- before LogMiner starts streaming).
        v_seed_id := 0;
        g_scalar_id_cnt := 0; g_lob_id_cnt := 0; g_wide_id_cnt := 0;
        g_part_id_cnt := 0; g_maxstr_id_cnt := 0; g_interval_id_cnt := 0;
        FOR i IN 1..50 LOOP
            v_seed_id := next_id;
            INSERT INTO olr_test.FUZZ_SCALAR (id, event_id, col_varchar, col_flag)
            VALUES (v_seed_id, 'SEED', DBMS_RANDOM.STRING('x', 20), 0);
            track_id(g_scalar_ids, g_scalar_id_cnt, v_seed_id);
        END LOOP;
        IF g_skip_lob = 0 THEN
            FOR i IN 1..5 LOOP
                v_seed_id := next_id;
                INSERT INTO olr_test.FUZZ_LOB (id, event_id, label, content)
                VALUES (v_seed_id, 'SEED', 'seed', 'seed');
                track_id(g_lob_ids, g_lob_id_cnt, v_seed_id);
            END LOOP;
        END IF;
        FOR i IN 1..20 LOOP
            v_seed_id := next_id;
            v_seed_region := REGIONS(rand_int(1, 5));
            INSERT INTO olr_test.FUZZ_PART (id, event_id, region, val, payload)
            VALUES (v_seed_id, 'SEED', v_seed_region, 0, 'seed');
            track_id(g_part_ids, g_part_id_cnt, v_seed_id);
        END LOOP;
        FOR i IN 1..10 LOOP
            INSERT INTO olr_test.FUZZ_NOPK (event_id, name, value, status)
            VALUES ('SEED', 'seed', 0, 'ACTIVE');
        END LOOP;
        COMMIT;
        -- Reset counters so tracked events start fresh
        g_event_seq := 0;
        g_insert_cnt := 0; g_total_ops := 0;

        -- Main loop
        LOOP
            EXIT WHEN SYSTIMESTAMP > v_deadline;

            -- Pick transaction pattern (weighted)
            v_txn_dice := rand_int(1, 100);

            IF v_txn_dice <= 55 THEN
                -- 55%: Immediate commit
                do_random_op;
                COMMIT;

            ELSIF v_txn_dice <= 70 THEN
                -- 15%: Batched commit (2-5 ops in one txn)
                v_batch := rand_int(2, 5);
                FOR j IN 1..v_batch LOOP
                    do_random_op;
                END LOOP;
                COMMIT;

            ELSIF v_txn_dice <= 80 THEN
                -- 10%: Full rollback
                do_random_op;
                ROLLBACK;
                g_rollback_cnt := g_rollback_cnt + 1;

            ELSIF v_txn_dice <= 90 THEN
                -- 10%: Savepoint + partial rollback
                do_random_op;
                SAVEPOINT sp_fuzz;
                do_random_op;
                ROLLBACK TO sp_fuzz;
                g_rollback_cnt := g_rollback_cnt + 1;
                do_random_op;
                COMMIT;

            ELSE
                -- 10%: Large transaction (10-30 ops before commit)
                v_batch := rand_int(10, 30);
                FOR j IN 1..v_batch LOOP
                    do_random_op;
                END LOOP;
                COMMIT;
            END IF;

            -- Throttle: ~0.5s pause per transaction to avoid overwhelming OLR
            DBMS_SESSION.SLEEP(0.5);

            -- Update stats periodically
            IF MOD(g_total_ops, 100) = 0 THEN
                update_stats;
            END IF;
        END LOOP;

        -- Final commit + stats
        COMMIT;
        update_stats;

        DBMS_OUTPUT.PUT_LINE('FUZZ_DONE: node=' || g_node_id ||
            ' inserts=' || g_insert_cnt ||
            ' updates=' || g_update_cnt ||
            ' deletes=' || g_delete_cnt ||
            ' rollbacks=' || g_rollback_cnt ||
            ' lobs=' || g_lob_cnt ||
            ' total=' || g_total_ops ||
            ' last_event_id=N' || g_node_id || '_' || LPAD(g_event_seq, 8, '0') ||
            ' elapsed_s=' || ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - v_start)) +
                EXTRACT(MINUTE FROM (SYSTIMESTAMP - v_start)) * 60 +
                EXTRACT(HOUR FROM (SYSTIMESTAMP - v_start)) * 3600));
    END;

END FUZZ_WKL;
/

-- ============================================================
-- Section 4: Capture SCN
-- ============================================================

DECLARE
    v_scn NUMBER;
BEGIN
    v_scn := DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER;
    DBMS_OUTPUT.PUT_LINE('FUZZ_SCN_START: ' || v_scn);
END;
/

EXIT
