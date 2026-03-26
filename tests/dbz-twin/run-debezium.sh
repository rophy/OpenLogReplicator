#!/usr/bin/env bash
# run-debezium.sh — Run Debezium twin-test for a scenario.
#
# Runs the same SQL scenario through two Debezium Server instances:
# one with LogMiner adapter, one with OLR adapter. Compares the CDC
# outputs to verify OLR compatibility.
#
# Usage: ./run-debezium.sh <scenario-name>
# Example: ./run-debezium.sh basic-crud
#
# Prerequisites:
#   - Services running: make -C tests/dbz-twin up
#   - OLR image built: make build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$(cd "$SQL_DIR/.." && pwd)"
DEBEZIUM_DIR="$TESTS_DIR/debezium"

SCENARIO="${1:?Usage: $0 <scenario-name>}"
ORACLE_CONTAINER="${ORACLE_CONTAINER:-dbz-oracle}"
RECEIVER_URL="${RECEIVER_URL:-http://localhost:8080}"
# DB_CONN is used inside the Oracle container via docker exec
DB_CONN="${DB_CONN:-olr_test/olr_test@//localhost:1521/XEPDB1}"
POLL_TIMEOUT="${POLL_TIMEOUT:-120}"

# Find scenario SQL
SCENARIO_SQL="$SQL_DIR/inputs/${SCENARIO}.sql"
if [[ ! -f "$SCENARIO_SQL" ]]; then
    SCENARIO_SQL="$SQL_DIR/inputs/${SCENARIO}.rac.sql"
fi
if [[ ! -f "$SCENARIO_SQL" ]]; then
    echo "ERROR: Scenario file not found: $SCENARIO" >&2
    exit 1
fi

# Skip tagged scenarios (they need special environments)
SCENARIO_TAGS=$(grep '^-- @TAG ' "$SCENARIO_SQL" 2>/dev/null | sed 's/^-- @TAG //' || true)
if [[ -n "$SCENARIO_TAGS" ]]; then
    echo "SKIP: $SCENARIO has tags ($SCENARIO_TAGS) — not supported in Debezium twin-test"
    exit 0
fi

# Skip DDL scenarios (mid-stream ALTER TABLE can't be replayed in twin-test)
if grep -q '^-- @DDL' "$SCENARIO_SQL" 2>/dev/null; then
    echo "SKIP: $SCENARIO uses @DDL — not compatible with Debezium twin-test"
    exit 0
fi

echo "=== Debezium twin-test: $SCENARIO ==="

# ---- Stage 1: Verify services ----
echo ""
echo "--- Stage 1: Verify services ---"

# Check receiver
if ! curl -sf "$RECEIVER_URL/health" > /dev/null 2>&1; then
    echo "ERROR: Receiver not responding at $RECEIVER_URL" >&2
    echo "Run: make -C tests/dbz-twin up" >&2
    exit 1
fi
echo "  Receiver: OK"

# Check Oracle
if ! docker exec "$ORACLE_CONTAINER" healthcheck.sh > /dev/null 2>&1; then
    echo "ERROR: Oracle not healthy in container $ORACLE_CONTAINER" >&2
    exit 1
fi
echo "  Oracle: OK"

# Check OLR container is running (port check unreliable — OLR only accepts one TCP client)
if ! docker ps --format '{{.Names}}' | grep -q '^dbz-olr$'; then
    echo "ERROR: OLR container not running" >&2
    echo "Check: docker logs dbz-olr" >&2
    exit 1
fi
echo "  OLR: OK"

echo "  Debezium containers: checking..."
for svc in dbz-logminer dbz-olr-adapter; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        echo "ERROR: Container $svc not running" >&2
        echo "Check: docker logs $svc" >&2
        exit 1
    fi
done
echo "  Debezium: OK"

# ---- Stage 2: Run DDL + restart connectors ----
echo ""
echo "--- Stage 2: Run DDL and restart connectors ---"

# Split scenario into DDL (CREATE/ALTER TABLE) and DML (INSERT/UPDATE/DELETE).
# Debezium's OLR adapter can't handle tables created after its initial schema snapshot,
# so we run DDL first, restart connectors to snapshot new schemas, then run DML.
docker cp "$SCENARIO_SQL" "$ORACLE_CONTAINER:/tmp/scenario.sql"

# Run the full SQL first to create tables (DML will happen but we ignore it this round)
docker exec "$ORACLE_CONTAINER" bash -c "
    echo 'SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
@/tmp/scenario.sql' | sqlplus -S $DB_CONN
" > /dev/null 2>&1
echo "  DDL executed (tables created)"

# Force log switch so DDL is in the redo
docker exec "$ORACLE_CONTAINER" bash -c "
    echo 'ALTER SYSTEM SWITCH LOGFILE;' | sqlplus -S / as sysdba
" > /dev/null 2>&1

# Recreate OLR + both Debezium connectors with clean state so they snapshot new tables
echo "  Restarting connectors..."
cd "$DEBEZIUM_DIR"
# Recreate (not restart) to clear tmpfs checkpoint and offset data
for svc in olr dbz-logminer dbz-olr; do
    docker compose rm -sf "$svc" > /dev/null 2>&1
done
# Determine compose project name for volume cleanup
COMPOSE_PROJECT=$(docker compose config 2>/dev/null | grep -m1 'name:' | awk '{print $2}')
COMPOSE_PROJECT="${COMPOSE_PROJECT:-debezium}"
docker volume rm -f "${COMPOSE_PROJECT}_dbz-logminer-data" "${COMPOSE_PROJECT}_dbz-olr-data" > /dev/null 2>&1
docker compose up -d olr dbz-logminer dbz-olr > /dev/null 2>&1
cd - > /dev/null

# Wait for OLR to start processing redo logs
echo "  Waiting for OLR to initialize..."
for i in $(seq 1 60); do
    if docker logs dbz-olr 2>&1 | tail -5 | grep -q "processing redo log"; then
        break
    fi
    sleep 2
done
echo "  OLR: ready"

# Wait for Debezium OLR adapter to connect and start streaming
echo "  Waiting for Debezium connectors..."
for i in $(seq 1 30); do
    if docker logs dbz-olr-adapter 2>&1 | tail -10 | grep -q "streaming client started successfully\|Starting streaming"; then
        break
    fi
    sleep 2
done
# Also wait for LogMiner to start streaming
for i in $(seq 1 30); do
    if docker logs dbz-logminer 2>&1 | tail -10 | grep -q "Starting streaming"; then
        break
    fi
    sleep 2
done
echo "  Connectors ready"

# ---- Stage 3: Reset receiver + run DML ----
echo ""
echo "--- Stage 3: Run scenario DML ---"
curl -sf -X POST "$RECEIVER_URL/reset" > /dev/null
echo "  Receiver state cleared"

# Re-run the scenario SQL — tables already exist so DDL is idempotent (DROP IF EXISTS + CREATE)
docker exec "$ORACLE_CONTAINER" bash -c "
    echo 'SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
@/tmp/scenario.sql' | sqlplus -S $DB_CONN
"
echo "  Scenario SQL executed"

# Force log switch so redo is archived
docker exec "$ORACLE_CONTAINER" bash -c "
    echo 'ALTER SYSTEM SWITCH LOGFILE;' | sqlplus -S / as sysdba
"
echo "  Log switch forced"

# ---- Stage 4: Insert sentinel ----
echo ""
echo "--- Stage 4: Insert sentinel ---"
docker exec "$ORACLE_CONTAINER" bash -c "
    echo \"DELETE FROM DEBEZIUM_SENTINEL;
INSERT INTO DEBEZIUM_SENTINEL VALUES (1, '$SCENARIO');
COMMIT;
EXIT;\" | sqlplus -S $DB_CONN
"
echo "  Sentinel inserted"

# Force another log switch for the sentinel
docker exec "$ORACLE_CONTAINER" bash -c "
    echo 'ALTER SYSTEM SWITCH LOGFILE;' | sqlplus -S / as sysdba
"

# ---- Stage 5: Wait for completion ----
echo ""
echo "--- Stage 5: Waiting for both connectors to process events ---"

START_TIME=$(date +%s)
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $POLL_TIMEOUT ]]; then
        echo "ERROR: Timeout after ${POLL_TIMEOUT}s waiting for events" >&2
        STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
        echo "  Final status: $STATUS" >&2
        echo "  Check logs: docker logs dbz-logminer && docker logs dbz-olr" >&2
        exit 1
    fi

    STATUS=$(curl -sf "$RECEIVER_URL/status" 2>/dev/null || echo '{}')
    LM_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_sentinel',False))" 2>/dev/null || echo "False")
    OLR_SENTINEL=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_sentinel',False))" 2>/dev/null || echo "False")
    LM_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('logminer_count',0))" 2>/dev/null || echo "0")
    OLR_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('olr_count',0))" 2>/dev/null || echo "0")

    printf "\r  [%3ds] LogMiner: %s events (sentinel: %s) | OLR: %s events (sentinel: %s)" \
        "$ELAPSED" "$LM_COUNT" "$LM_SENTINEL" "$OLR_COUNT" "$OLR_SENTINEL"

    if [[ "$LM_SENTINEL" == "True" && "$OLR_SENTINEL" == "True" ]]; then
        echo ""
        echo "  Both connectors have processed all events"
        break
    fi

    sleep 2
done

# ---- Stage 6: Compare outputs ----
echo ""
echo "--- Stage 6: Compare LogMiner vs OLR Debezium output ---"

LM_FILE="$DEBEZIUM_DIR/output/logminer.jsonl"
OLR_FILE="$DEBEZIUM_DIR/output/olr.jsonl"

if [[ ! -s "$LM_FILE" ]]; then
    echo "ERROR: LogMiner output is empty: $LM_FILE" >&2
    exit 1
fi
if [[ ! -s "$OLR_FILE" ]]; then
    echo "ERROR: OLR output is empty: $OLR_FILE" >&2
    exit 1
fi

if python3 "$SCRIPT_DIR/compare-debezium.py" "$LM_FILE" "$OLR_FILE"; then
    echo ""
    echo "=== PASS: Debezium twin-test '$SCENARIO' ==="
else
    echo ""
    echo "=== FAIL: Debezium twin-test '$SCENARIO' ==="
    echo "  LogMiner output: $LM_FILE"
    echo "  OLR output:      $OLR_FILE"
    exit 1
fi
