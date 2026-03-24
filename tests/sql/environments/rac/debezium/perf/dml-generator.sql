-- DML generator for performance testing.
-- Runs continuous INSERT/UPDATE/DELETE on OLR_TEST.PERF_BENCH.
--
-- Parameters (substitution variables):
--   &1 = batch size per commit (default 50)
--   &2 = number of batches (default 1000)
--   &3 = node_id (1 or 2)
--   &4 = start ID offset (default 1)
--
-- Each batch: ~70% INSERT, ~20% UPDATE, ~10% DELETE
-- Commits after each batch for realistic CDC workload.

SET FEEDBACK OFF
SET SERVEROUTPUT ON

DECLARE
    v_batch_size  PLS_INTEGER := &1;
    v_batches     PLS_INTEGER := &2;
    v_node_id     PLS_INTEGER := &3;
    v_start_id    PLS_INTEGER := &4;
    v_next_id     PLS_INTEGER := v_start_id;
    v_insert_cnt  PLS_INTEGER := 0;
    v_update_cnt  PLS_INTEGER := 0;
    v_delete_cnt  PLS_INTEGER := 0;
    v_total       PLS_INTEGER := 0;
    v_start_ts    TIMESTAMP := SYSTIMESTAMP;
    v_rand        NUMBER;
    v_target_id   PLS_INTEGER;
BEGIN
    FOR batch IN 1..v_batches LOOP
        FOR i IN 1..v_batch_size LOOP
            v_rand := DBMS_RANDOM.VALUE(0, 1);

            IF v_rand < 0.7 OR v_next_id = v_start_id THEN
                -- INSERT (70% or first row)
                INSERT INTO olr_test.PERF_BENCH (id, val, node_id, batch_num, created)
                VALUES (v_next_id,
                        DBMS_RANDOM.STRING('x', 100),
                        v_node_id,
                        batch,
                        SYSTIMESTAMP);
                v_next_id := v_next_id + 1;
                v_insert_cnt := v_insert_cnt + 1;

            ELSIF v_rand < 0.9 THEN
                -- UPDATE (20%) — target a recent row
                v_target_id := v_start_id + MOD(ABS(DBMS_RANDOM.RANDOM), GREATEST(v_next_id - v_start_id, 1));
                UPDATE olr_test.PERF_BENCH
                   SET val = DBMS_RANDOM.STRING('x', 100),
                       batch_num = batch
                 WHERE id = v_target_id AND node_id = v_node_id;
                v_update_cnt := v_update_cnt + 1;

            ELSE
                -- DELETE (10%) — target an old row
                v_target_id := v_start_id + MOD(ABS(DBMS_RANDOM.RANDOM), GREATEST(v_next_id - v_start_id, 1));
                DELETE FROM olr_test.PERF_BENCH
                 WHERE id = v_target_id AND node_id = v_node_id;
                v_delete_cnt := v_delete_cnt + 1;
            END IF;

            v_total := v_total + 1;
        END LOOP;
        COMMIT;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('PERF_DML_DONE: node=' || v_node_id ||
        ' inserts=' || v_insert_cnt ||
        ' updates=' || v_update_cnt ||
        ' deletes=' || v_delete_cnt ||
        ' total=' || v_total ||
        ' batches=' || v_batches ||
        ' elapsed_ms=' || EXTRACT(SECOND FROM (SYSTIMESTAMP - v_start_ts)) * 1000);
END;
/
EXIT
