#!/usr/bin/env bash
# fuzz-test.sh — Randomized OLR accuracy test with streaming validation.
#
# Runs a PL/SQL fuzz workload on both RAC nodes, streams CDC events through
# Kafka to a consumer that writes to SQLite, and a validator that continuously
# compares LogMiner vs OLR output by event_id.
#
# Usage: ./fuzz-test.sh [duration-minutes]
#   duration-minutes  How long to run the fuzz workload (default: 30)
#
# Prerequisites:
#   - RAC VM running with containers started
#   - OLR image loaded on VM (podman load)
#   - One-time setup done (./setup.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBZ_TWIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$(cd "$DBZ_TWIN_DIR/.." && pwd)"
RAC_ENV_DIR="$TESTS_DIR/environments/rac"

DURATION_MINUTES="${1:-30}"
DURATION_SECONDS=$(( DURATION_MINUTES * 60 ))

# ---- RAC configuration (auto-detect VM IP) ----
source "$RAC_ENV_DIR/vm-env.sh"
OLR_IMAGE="${OLR_IMAGE:-docker.io/library/olr-dev:latest}"
RAC_NODE1="${RAC_NODE1:-racnodep1}"
RAC_NODE2="${RAC_NODE2:-racnodep2}"
ORACLE_SID1="${ORACLE_SID1:-ORCLCDB1}"
ORACLE_SID2="${ORACLE_SID2:-ORCLCDB2}"
DB_CONN1="${DB_CONN1:-olr_test/olr_test@//racnodep1:1521/ORCLPDB}"
DB_CONN2="${DB_CONN2:-olr_test/olr_test@//racnodep2:1521/ORCLPDB}"

OLR_CONTAINER="olr-debezium"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose-fuzz.yaml"

# ---- SSH helpers ----
_vm_sqlplus() {
    local node="$1" sid="$2" conn="$3" sql_file="$4"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $node su - oracle -c 'export ORACLE_SID=$sid; sqlplus -S \"$conn\" @$sql_file'"
}

_vm_copy_in() {
    local local_path="$1" container_path="$2" node="$3"
    local staging="/tmp/_fuzz_staging_$$"
    scp $_SSH_OPTS "$local_path" "${VM_USER}@${VM_HOST}:${staging}"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman cp ${staging} ${node}:${container_path}; rm -f ${staging}"
}

_exec_sysdba() {
    local sql_file="$1"
    local remote="/tmp/$(basename "$sql_file")"
    _vm_copy_in "$sql_file" "$remote" "$RAC_NODE1"
    _vm_sqlplus "$RAC_NODE1" "$ORACLE_SID1" "/ as sysdba" "$remote"
}

_exec_user() {
    local sql_file="$1"
    local node="${2:-$RAC_NODE1}" sid="${3:-$ORACLE_SID1}" conn="${4:-$DB_CONN1}"
    local remote="/tmp/$(basename "$sql_file")"
    _vm_copy_in "$sql_file" "$remote" "$node"
    _vm_sqlplus "$node" "$sid" "$conn" "$remote"
}

_olr_memory_mb() {
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $OLR_CONTAINER sh -c 'cat /proc/\$(pgrep -f OpenLogReplicator | head -1)/status 2>/dev/null | grep VmRSS | awk \"{printf \\\"%.0f\\\", \\\$2/1024}\"'" 2>/dev/null || echo "N/A"
}

WORK_DIR=$(mktemp -d /tmp/fuzz_rac_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== OLR RAC Fuzz Test ==="
echo "  Duration: ${DURATION_MINUTES} minutes"
echo "  Mode: PL/SQL fuzz workload (7 tables, streaming Kafka validation)"
echo ""

# ---- Stage 1: Verify prerequisites ----
echo "--- Stage 1: Verify prerequisites ---"

if ! ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec $RAC_NODE1 su - oracle -c 'export ORACLE_SID=$ORACLE_SID1; printf \"SELECT 1 FROM dual;\nEXIT;\n\" | sqlplus -S / as sysdba'" 2>/dev/null | grep -q "1"; then
    echo "ERROR: RAC Oracle not reachable on $VM_HOST" >&2
    exit 1
fi
echo "  Oracle RAC: OK"

# ---- Stage 2: Deploy fuzz workload ----
echo ""
echo "--- Stage 2: Deploy fuzz workload ---"

_vm_copy_in "$SCRIPT_DIR/perf/fuzz-workload.sql" "/tmp/fuzz-workload.sql" "$RAC_NODE1"
SETUP_OUT=$(_vm_sqlplus "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1" "/tmp/fuzz-workload.sql")
echo "$SETUP_OUT"

# Log switch
cat > "$WORK_DIR/log_switch.sql" <<'SQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH ALL LOGFILE;
BEGIN DBMS_SESSION.SLEEP(2); END;
/
EXIT
SQL
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

# ---- Stage 3: Start infrastructure ----
echo ""
echo "--- Stage 3: Start infrastructure ---"

# Stop any existing containers
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman stop -t5 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"
docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null

# Start Kafka + consumer + validator
docker compose -f "$COMPOSE_FILE" up -d 2>&1
echo "  Kafka + consumer + validator: starting"

# Wait for Kafka
echo "  Waiting for Kafka..."
for i in $(seq 1 30); do
    if docker exec fuzz-kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 > /dev/null 2>&1; then
        echo "  Kafka: ready"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "ERROR: Kafka did not start" >&2
        exit 1
    fi
    sleep 2
done

# Deploy OLR config and start OLR
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "mkdir -p /root/olr-debezium/config /root/olr-debezium/checkpoint"
scp $_SSH_OPTS "$SCRIPT_DIR/config/olr-config.json" "${VM_USER}@${VM_HOST}:/root/olr-debezium/config/"
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "rm -rf /root/olr-debezium/checkpoint/* && chown -R 1000:54335 /root/olr-debezium/checkpoint"

echo "  Starting OLR on RAC VM..."
SCAN_IP=$(ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec racnodep1 getent hosts racnodepc1-scan 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null)
if [[ -z "$SCAN_IP" ]]; then
    echo "ERROR: Failed to resolve racnodepc1-scan IP from RAC VM" >&2
    exit 1
fi
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman run -d --name $OLR_CONTAINER \
    --user 1000:54335 \
    --network rac_pub1_nw \
    --add-host racnodepc1-scan:${SCAN_IP} \
    -p 5000:5000 \
    -v /root/olr-debezium/config:/config:ro,Z \
    -v /root/olr-debezium/checkpoint:/olr-data/checkpoint:Z \
    -v /shared/redo:/shared/redo:ro \
    $OLR_IMAGE \
    -r -f /config/olr-config.json" > /dev/null

# Wait for OLR
echo "  Waiting for OLR..."
for i in $(seq 1 90); do
    if ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman logs $OLR_CONTAINER 2>&1 | tail -5" 2>/dev/null | grep -q "processing redo log"; then
        echo "  OLR: ready"
        break
    fi
    if [[ $i -eq 90 ]]; then
        echo "ERROR: OLR did not start" >&2
        ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman logs --tail 20 $OLR_CONTAINER" 2>/dev/null
        exit 1
    fi
    sleep 2
done

# Wait for Debezium connectors
echo "  Waiting for Debezium connectors..."
for i in $(seq 1 60); do
    LM_OK=false; OLR_OK=false
    docker logs fuzz-dbz-logminer 2>&1 | tail -10 | grep -q "Starting streaming" && LM_OK=true
    docker logs fuzz-dbz-olr 2>&1 | tail -10 | grep -q "streaming client started\|Starting streaming" && OLR_OK=true
    if $LM_OK && $OLR_OK; then
        echo "  Debezium: ready"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "ERROR: Debezium connectors did not start" >&2
        echo "  LogMiner: $LM_OK, OLR: $OLR_OK"
        exit 1
    fi
    sleep 2
done

INIT_MEM=$(_olr_memory_mb)
echo "  OLR initial memory: ${INIT_MEM} MB"

# ---- Stage 4: Run fuzz workload ----
echo ""
echo "--- Stage 4: Running fuzz workload for ${DURATION_MINUTES} minutes ---"

cat > "$WORK_DIR/fuzz_node1.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC FUZZ_WKL.run(p_duration_secs => ${DURATION_SECONDS}, p_seed => 42, p_node_id => 1);
EXIT;
SQL
cat > "$WORK_DIR/fuzz_node2.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC FUZZ_WKL.run(p_duration_secs => ${DURATION_SECONDS}, p_seed => 137, p_node_id => 2);
EXIT;
SQL

_vm_copy_in "$WORK_DIR/fuzz_node1.sql" "/tmp/fuzz_node1.sql" "$RAC_NODE1"
_vm_copy_in "$WORK_DIR/fuzz_node2.sql" "/tmp/fuzz_node2.sql" "$RAC_NODE2"

ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec $RAC_NODE1 su - oracle -c 'export ORACLE_SID=$ORACLE_SID1; sqlplus -S $DB_CONN1 @/tmp/fuzz_node1.sql'" \
    > "$WORK_DIR/fuzz_out1.log" 2>&1 &
FUZZ_PID1=$!

ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman exec $RAC_NODE2 su - oracle -c 'export ORACLE_SID=$ORACLE_SID2; sqlplus -S $DB_CONN2 @/tmp/fuzz_node2.sql'" \
    > "$WORK_DIR/fuzz_out2.log" 2>&1 &
FUZZ_PID2=$!

echo "  Fuzz running on both nodes (PIDs: $FUZZ_PID1, $FUZZ_PID2)"

# Monitor progress while workload runs
while kill -0 $FUZZ_PID1 2>/dev/null || kill -0 $FUZZ_PID2 2>/dev/null; do
    MEM=$(_olr_memory_mb)
    # Get latest validator status from container logs
    VSTATUS=$(docker logs --tail 1 fuzz-validator 2>/dev/null || echo "waiting...")
    printf "\r  [OLR: %s MB] %s  " "$MEM" "$VSTATUS"
    sleep 15
done
echo ""

wait $FUZZ_PID1 || true
wait $FUZZ_PID2 || true

echo "  Node 1: $(grep 'FUZZ_DONE:' "$WORK_DIR/fuzz_out1.log" || echo 'no output')"
echo "  Node 2: $(grep 'FUZZ_DONE:' "$WORK_DIR/fuzz_out2.log" || echo 'no output')"

# Extra log switches to flush redo
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null
sleep 3
_exec_sysdba "$WORK_DIR/log_switch.sql" > /dev/null

# ---- Stage 5: Wait for pipeline drain + validation ----
echo ""
echo "--- Stage 5: Waiting for pipeline drain and validation ---"
echo "  Validator will idle-timeout after processing all events..."

# Wait for validator to complete (it exits after IDLE_TIMEOUT of no new events)
docker wait fuzz-validator > /dev/null 2>&1 || true
VALIDATOR_EXIT=$(docker inspect fuzz-validator --format '{{.State.ExitCode}}' 2>/dev/null || echo "1")

# ---- Stage 6: Results ----
echo ""
echo "--- Stage 6: Results ---"

# Save full validator log for troubleshooting
VALIDATOR_LOG="/tmp/fuzz-validator-$(date +%Y%m%d-%H%M%S).log"
docker logs fuzz-validator > "$VALIDATOR_LOG" 2>&1
echo "  Validator log: $VALIDATOR_LOG"
# Show summary
tail -15 "$VALIDATOR_LOG"

FINAL_MEM=$(_olr_memory_mb)
echo ""
echo "  OLR memory: ${INIT_MEM} MB -> ${FINAL_MEM} MB"

# OLR error checks
OLR_ERRORS=$(ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman logs $OLR_CONTAINER 2>&1 | grep -c 'ERROR\|ASAN\|AddressSanitizer'" 2>/dev/null || echo "0")
if [[ "$OLR_ERRORS" -gt 0 ]]; then
    echo "  WARNING: $OLR_ERRORS OLR errors detected"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman logs $OLR_CONTAINER 2>&1 | grep 'ERROR\|ASAN' | tail -5" 2>/dev/null
fi

echo ""
if [[ "$VALIDATOR_EXIT" == "0" ]]; then
    echo "=== PASS: Fuzz test completed ==="
else
    echo "=== FAIL: Fuzz test found mismatches ==="
fi

# Cleanup
docker compose -f "$COMPOSE_FILE" down 2>/dev/null
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman stop -t5 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"

exit "$VALIDATOR_EXIT"
