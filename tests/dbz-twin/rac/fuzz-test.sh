#!/usr/bin/env bash
# fuzz-test.sh — Randomized OLR accuracy test with streaming validation.
#
# Runs a PL/SQL fuzz workload on both RAC nodes, streams CDC events through
# Kafka to a consumer that writes to SQLite, and a validator that continuously
# compares LogMiner vs OLR output by event_id.
#
# Usage: ./fuzz-test.sh <action> [options]
#
# Actions:
#   up                    Start infrastructure (Kafka, Debezium, consumer, validator, OLR)
#   run [duration-min]    Deploy fuzz workload and run for N minutes (default: 30)
#   status                Show consumer/validator status and OLR memory
#   validate              Run validator (wait for idle timeout, report results)
#   logs [component]      Show logs (kafka, logminer, olr, consumer, validator, olr-vm)
#   down                  Stop and remove all containers + volumes
#   help                  Show this help
#
# Typical workflow:
#   ./fuzz-test.sh up              # start infrastructure
#   ./fuzz-test.sh run 60          # run 60-minute fuzz workload
#   ./fuzz-test.sh status          # check progress
#   ./fuzz-test.sh validate        # wait for drain + validate
#   ./fuzz-test.sh logs validator  # investigate mismatches
#   ./fuzz-test.sh down            # clean up
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

_seed_debezium_offsets() {
    local scn="$1"
    local offset_val="{\"scn\":\"${scn}\",\"snapshot_scn\":\"${scn}\",\"snapshot\":\"true\",\"snapshot_completed\":\"true\"}"

    # topic_prefix matches debezium.source.topic.prefix in each connector config
    # offset_topic matches debezium.source.offset.storage.topic
    local -A topics=( [logminer]=dbz-lm-offsets [olr]=dbz-olr-offsets )
    for topic_prefix in "${!topics[@]}"; do
        local offset_topic="${topics[$topic_prefix]}"
        local offset_key="[\"kafka\",{\"server\":\"${topic_prefix}\"}]"

        # Create compacted offset topic
        docker exec fuzz-kafka /opt/kafka/bin/kafka-topics.sh \
            --bootstrap-server localhost:9092 \
            --create --topic "$offset_topic" \
            --partitions 1 --replication-factor 1 \
            --config cleanup.policy=compact 2>/dev/null

        # Produce seed offset
        echo "${offset_key}|${offset_val}" | docker exec -i fuzz-kafka /opt/kafka/bin/kafka-console-producer.sh \
            --bootstrap-server localhost:9092 \
            --topic "$offset_topic" \
            --property parse.key=true \
            --property key.separator='|' 2>/dev/null

        echo "  Seeded $offset_topic: SCN=$scn"
    done
}

_olr_memory_mb() {
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $OLR_CONTAINER sh -c 'cat /proc/\$(pgrep -f OpenLogReplicator | head -1)/status 2>/dev/null | grep VmRSS | awk \"{printf \\\"%.0f\\\", \\\$2/1024}\"'" 2>/dev/null || echo "N/A"
}

# ---- Actions ----

action_help() {
    sed -n '2,/^$/s/^# \?//p' "$0"
}

action_up() {
    echo "=== Starting fuzz test infrastructure ==="

    # Verify RAC
    if ! ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $RAC_NODE1 su - oracle -c 'export ORACLE_SID=$ORACLE_SID1; printf \"SELECT 1 FROM dual;\nEXIT;\n\" | sqlplus -S / as sysdba'" 2>/dev/null | grep -q "1"; then
        echo "ERROR: RAC Oracle not reachable on $VM_HOST" >&2
        exit 1
    fi
    echo "  Oracle RAC: OK"

    # Deploy fuzz workload (creates tables + PL/SQL package)
    echo "  Deploying fuzz workload..."
    _vm_copy_in "$SCRIPT_DIR/perf/fuzz-workload.sql" "/tmp/fuzz-workload.sql" "$RAC_NODE1"
    _vm_sqlplus "$RAC_NODE1" "$ORACLE_SID1" "$DB_CONN1" "/tmp/fuzz-workload.sql"

    # Stop existing OLR
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman stop -t5 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"

    # Tear down previous containers and volumes
    docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null

    # Start Kafka first (Debezium needs pre-seeded offsets before starting)
    docker compose -f "$COMPOSE_FILE" up -d kafka 2>&1
    echo "  Kafka: starting"

    # Wait for Kafka
    echo "  Waiting for Kafka..."
    for i in $(seq 1 30); do
        if docker exec fuzz-kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 > /dev/null 2>&1; then
            echo "  Kafka: ready"
            break
        fi
        [[ $i -eq 30 ]] && { echo "ERROR: Kafka did not start" >&2; exit 1; }
        sleep 2
    done

    # Get current SCN from Oracle (after table deploy, so this SCN is post-DDL)
    echo "  Getting current SCN..."
    local current_scn
    current_scn=$(ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $RAC_NODE1 su - oracle -c 'export ORACLE_SID=$ORACLE_SID1; printf \"SELECT current_scn FROM v\\\$database;\nEXIT;\n\" | sqlplus -S / as sysdba'" 2>/dev/null \
        | grep -E '^\s*[0-9]+' | tr -d ' ')
    if [[ -z "$current_scn" ]]; then
        echo "ERROR: Failed to get current SCN" >&2
        exit 1
    fi
    echo "  Current SCN: $current_scn"

    # Pre-seed Debezium offset topics so connectors start from this SCN
    _seed_debezium_offsets "$current_scn"

    # Start remaining services (Debezium + consumer)
    docker compose -f "$COMPOSE_FILE" up -d 2>&1
    echo "  Debezium + consumer: starting"

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
            "podman logs $OLR_CONTAINER 2>&1 | grep -q 'processing redo log'"; then
            echo "  OLR: ready"
            break
        fi
        [[ $i -eq 90 ]] && { echo "ERROR: OLR did not start" >&2; exit 1; }
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
        [[ $i -eq 60 ]] && { echo "ERROR: Debezium connectors did not start" >&2; exit 1; }
        sleep 2
    done

    echo ""
    echo "  OLR memory: $(_olr_memory_mb) MB"
    echo ""
    echo "=== Infrastructure ready. Run: ./fuzz-test.sh run [minutes] ==="
}

action_run() {
    local duration_min="${1:-30}"
    local duration_sec=$(( duration_min * 60 ))
    local skip_lob="${SKIP_LOB:-0}"

    if [[ "$skip_lob" == "1" ]]; then
        echo "=== Running fuzz workload for ${duration_min} minutes (LOB skipped) ==="
    else
        echo "=== Running fuzz workload for ${duration_min} minutes ==="
    fi

    local work_dir
    work_dir=$(mktemp -d /tmp/fuzz_rac_XXXXXX)

    # Log switch helper
    cat > "$work_dir/log_switch.sql" <<'SQL'
SET FEEDBACK OFF
ALTER SYSTEM SWITCH ALL LOGFILE;
BEGIN DBMS_SESSION.SLEEP(2); END;
/
EXIT
SQL
    _exec_sysdba "$work_dir/log_switch.sql" > /dev/null

    # Create runner scripts
    cat > "$work_dir/fuzz_node1.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC FUZZ_WKL.run(p_duration_secs => ${duration_sec}, p_seed => 42, p_node_id => 1, p_skip_lob => ${skip_lob});
EXIT;
SQL
    cat > "$work_dir/fuzz_node2.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC FUZZ_WKL.run(p_duration_secs => ${duration_sec}, p_seed => 137, p_node_id => 2, p_skip_lob => ${skip_lob});
EXIT;
SQL

    _vm_copy_in "$work_dir/fuzz_node1.sql" "/tmp/fuzz_node1.sql" "$RAC_NODE1"
    _vm_copy_in "$work_dir/fuzz_node2.sql" "/tmp/fuzz_node2.sql" "$RAC_NODE2"

    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $RAC_NODE1 su - oracle -c 'export ORACLE_SID=$ORACLE_SID1; sqlplus -S $DB_CONN1 @/tmp/fuzz_node1.sql'" \
        > "$work_dir/fuzz_out1.log" 2>&1 &
    local pid1=$!

    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman exec $RAC_NODE2 su - oracle -c 'export ORACLE_SID=$ORACLE_SID2; sqlplus -S $DB_CONN2 @/tmp/fuzz_node2.sql'" \
        > "$work_dir/fuzz_out2.log" 2>&1 &
    local pid2=$!

    echo "  Fuzz running on both nodes (PIDs: $pid1, $pid2)"
    echo "  Monitor: ./fuzz-test.sh status"

    # Monitor until workload finishes
    while kill -0 $pid1 2>/dev/null || kill -0 $pid2 2>/dev/null; do
        local mem=$(_olr_memory_mb)
        local consumer_status
        consumer_status=$(docker logs --tail 1 fuzz-consumer 2>/dev/null | grep -o '\[consumer\].*' || echo "consumer starting...")
        printf "\r  [OLR: %s MB] %s  " "$mem" "$consumer_status"
        sleep 15
    done
    echo ""

    local rc1=0 rc2=0
    wait $pid1 || rc1=$?
    wait $pid2 || rc2=$?

    # Show workload summary from each node
    local done1 done2
    done1=$(grep 'FUZZ_DONE:' "$work_dir/fuzz_out1.log" 2>/dev/null || true)
    done2=$(grep 'FUZZ_DONE:' "$work_dir/fuzz_out2.log" 2>/dev/null || true)
    if [[ -n "$done1" ]]; then
        echo "  Node 1: $done1"
    else
        echo "  Node 1: workload finished (no summary line)"
    fi
    if [[ -n "$done2" ]]; then
        echo "  Node 2: $done2"
    else
        echo "  Node 2: workload finished (no summary line)"
    fi

    if [[ $rc1 -ne 0 || $rc2 -ne 0 ]]; then
        echo "ERROR: fuzz workload failed on one or more RAC nodes (rc1=$rc1, rc2=$rc2)" >&2
        echo "  Check logs: $work_dir/fuzz_out1.log, $work_dir/fuzz_out2.log" >&2
        exit 1
    fi

    # Insert sentinel row and capture its commit SCN as watermark.
    # Both CDC adapters will process this INSERT, so waiting for them
    # to reach this SCN guarantees all prior DML has been processed.
    cat > "$work_dir/sentinel.sql" <<'SQL'
SET FEEDBACK OFF
SET HEADING OFF
DELETE FROM FUZZ_SCALAR WHERE id = -1;
INSERT INTO FUZZ_SCALAR (id, event_id, col_varchar, col_flag)
VALUES (-1, 'SENTINEL', 'db-check-watermark', 0);
COMMIT;
EXIT
SQL
    _exec_user "$work_dir/sentinel.sql" > /dev/null
    echo "  Sentinel row committed."

    # Flush redo so adapters see the sentinel
    _exec_sysdba "$work_dir/log_switch.sql" > /dev/null
    sleep 3
    _exec_sysdba "$work_dir/log_switch.sql" > /dev/null

    rm -rf "$work_dir"

    echo ""
    echo "=== Workload complete. Run: ./fuzz-test.sh validate ==="
}

action_status() {
    echo "=== Fuzz Test Status ==="
    echo ""

    # Containers
    echo "Containers:"
    docker ps -a --filter "name=fuzz" --format "  {{.Names}}: {{.Status}}" 2>/dev/null || echo "  (none)"
    echo ""

    # OLR
    echo "OLR:"
    echo "  Memory: $(_olr_memory_mb) MB"
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman logs --tail 3 $OLR_CONTAINER" 2>/dev/null | sed 's/^/  /' || echo "  (not running)"
    echo ""

    # Consumer
    echo "Consumer:"
    docker logs --tail 3 fuzz-consumer 2>/dev/null | sed 's/^/  /' || echo "  (not running)"
    echo ""

    # Validator
    echo "Validator:"
    docker logs --tail 3 fuzz-validator 2>/dev/null | sed 's/^/  /' || echo "  (not running)"
    echo ""

    # Kafka topics
    echo "Kafka topics:"
    docker exec fuzz-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null | sed 's/^/  /' || echo "  (kafka not running)"
}

action_validate() {
    echo "=== Running validation ==="

    # Wait for consumer to catch up (no new events for 30s)
    echo "  Waiting for consumer to finish processing..."
    local prev_line="" idle_count=0
    while true; do
        local cur_line
        cur_line=$(docker logs --tail 1 fuzz-consumer 2>/dev/null | grep -o '\[consumer\].*' || echo "")
        if [[ "$cur_line" == "$prev_line" ]]; then
            idle_count=$(( idle_count + 1 ))
            [[ $idle_count -ge 6 ]] && break  # 30s idle
        else
            idle_count=0
            prev_line=$cur_line
        fi
        sleep 5
    done
    # Show final consumer counts
    local final_counts
    final_counts=$(docker logs --tail 1 fuzz-consumer 2>/dev/null | grep -o '\[consumer\].*' || echo "unknown")
    echo "  Consumer idle for 30s. Last status: $final_counts"

    # Start validator (uses 'validate' profile)
    local exit_code=0
    docker compose -f "$COMPOSE_FILE" run --rm validator || exit_code=$?
    echo ""
    echo "  OLR memory: $(_olr_memory_mb) MB"

    # OLR errors
    local olr_errors
    olr_errors=$(ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman logs $OLR_CONTAINER 2>&1 | grep -c 'ERROR\|ASAN\|AddressSanitizer'" 2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ -z "$olr_errors" ]] && olr_errors=0
    if [[ "$olr_errors" -gt 0 ]]; then
        echo "  WARNING: $olr_errors OLR errors detected"
        ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
            "podman logs $OLR_CONTAINER 2>&1 | grep 'ERROR\|ASAN' | tail -5" 2>/dev/null
    fi

    echo ""
    if [[ "$exit_code" -eq 0 ]]; then
        echo "=== PASS: Fuzz test completed ==="
    else
        echo "=== FAIL: Fuzz test found mismatches ==="
    fi

    return "$exit_code"
}

action_logs() {
    local component="${1:-}"
    case "$component" in
        kafka)      docker logs fuzz-kafka 2>&1 ;;
        logminer)   docker logs fuzz-dbz-logminer 2>&1 ;;
        olr)        docker logs fuzz-dbz-olr 2>&1 ;;
        consumer)   docker logs fuzz-consumer 2>&1 ;;
        validator)  docker logs fuzz-validator 2>&1 ;;
        olr-vm)     ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman logs $OLR_CONTAINER" 2>/dev/null ;;
        "")
            echo "Usage: $0 logs <component>"
            echo "Components: kafka, logminer, olr, consumer, validator, olr-vm"
            ;;
        *)
            echo "Unknown component: $component" >&2
            echo "Components: kafka, logminer, olr, consumer, validator, olr-vm"
            exit 1
            ;;
    esac
}

action_down() {
    echo "=== Stopping fuzz test infrastructure ==="
    docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null
    ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman stop -t5 $OLR_CONTAINER 2>/dev/null; podman rm $OLR_CONTAINER 2>/dev/null; true"
    echo "  Done."
}

# ---- Main ----

ACTION="${1:-help}"
shift || true

action_db_check() {
    echo "=== 3-Way DB Check ==="

    # Get SQLite DB path from consumer container volume
    local tmp_db="/tmp/fuzz-db-check.db"
    docker cp fuzz-consumer:/app/data/fuzz.db "$tmp_db" 2>/dev/null || {
        echo "ERROR: Cannot copy fuzz.db from consumer container" >&2
        return 1
    }

    # The script will poll the SQLite DB (via re-copy) waiting for sentinel.
    # Pass the container name so it can re-copy during polling.
    SQLITE_DB="$tmp_db" ORACLE_HOST="$VM_HOST" \
        python3 "$SCRIPT_DIR/db-check.py"
}

case "$ACTION" in
    up)         action_up ;;
    run)        action_run "$@" ;;
    status)     action_status ;;
    validate)   action_validate ;;
    db-check)   action_db_check ;;
    logs)       action_logs "$@" ;;
    down)       action_down ;;
    help|--help|-h)  action_help ;;
    *)
        echo "Unknown action: $ACTION" >&2
        echo ""
        action_help
        exit 1
        ;;
esac
