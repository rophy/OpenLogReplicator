#!/usr/bin/env bash
# Performance test: Debezium OLR adapter vs LogMiner adapter.
#
# Uses Swingbench (charbench) to generate sustained OLTP load on Oracle RAC
# while both Debezium adapters consume events. Measures throughput and latency.
#
# Usage: ./run.sh [duration_seconds] [swingbench_users]
#   duration_seconds   Swingbench run time (default: 300)
#   swingbench_users   Concurrent Swingbench users (default: 8)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBZ_RAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DBZ_TWIN_DIR="$(cd "$DBZ_RAC_DIR/.." && pwd)"
TESTS_DIR="$(cd "$DBZ_TWIN_DIR/.." && pwd)"
RAC_ENV_DIR="$TESTS_DIR/environments/rac"

source "$RAC_ENV_DIR/vm-env.sh"

DURATION="${1:-300}"
SB_USERS="${2:-8}"

SWINGBENCH_HOME="${SWINGBENCH_HOME:-$HOME/tools/swingbench}"
CHARBENCH="$SWINGBENCH_HOME/bin/charbench"
SB_CONFIG="$SWINGBENCH_HOME/configs/SOE_Server_Side_V2.xml"

OLR_IMAGE="${OLR_IMAGE:-docker.io/library/olr-dev:latest}"
OLR_CONTAINER="olr-debezium"
RECEIVER_URL="${RECEIVER_URL:-http://localhost:8080}"

SB_RT=$(printf "%02d:%02d.%02d" $(( DURATION / 3600 )) $(( (DURATION % 3600) / 60 )) $(( DURATION % 60 )))

if [[ ! -x "$CHARBENCH" ]]; then
    echo "ERROR: Swingbench not found at $SWINGBENCH_HOME" >&2
    exit 1
fi

_poll_metrics() {
    curl -sf "$RECEIVER_URL/metrics" 2>/dev/null || echo '{}'
}

_print_metrics() {
    local label="$1"
    echo "$label"
    _poll_metrics | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ch in ('logminer', 'olr'):
    m = d.get(ch, {})
    print(f'  {ch:10s}: {m.get(\"count\",0):>8d} events | '
          f'{m.get(\"throughput_total_eps\",0):>7.1f} total eps | '
          f'{m.get(\"throughput_10s_eps\",0):>7.1f} 10s eps | '
          f'p50={m.get(\"latency_p50_ms\",0):>7.0f} p95={m.get(\"latency_p95_ms\",0):>7.0f} ms')
"
}

echo "=== Debezium Performance Test: OLR vs LogMiner ==="
echo "  Swingbench: ${SB_USERS} users, ${DURATION}s"
echo "  RAC VM: ${VM_HOST}"
echo ""

# ---- Stage 1: Setup ----
echo "--- Stage 1: Setup ---"

# Push perf OLR config to VM and clean state
scp $_SSH_OPTS "$SCRIPT_DIR/olr-config.json" \
    "${VM_USER}@${VM_HOST}:/root/olr-debezium/config/olr-config.json" > /dev/null
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
    "podman rm -f $OLR_CONTAINER 2>/dev/null; rm -rf /root/olr-debezium/checkpoint/*; true" > /dev/null

# Generate prometheus config with current VM_HOST
# (node_exporter + cAdvisor run on VM, see DEPLOY.md steps 3.5-3.6)
cat > "$SCRIPT_DIR/config/prometheus.yml" <<PROMCFG
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['${VM_HOST}:9100']
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['${VM_HOST}:9101']
PROMCFG

# Start services via docker compose
cd "$SCRIPT_DIR"
docker compose down -v 2>/dev/null || true
docker compose up -d receiver prometheus 2>/dev/null
sleep 2
curl -sf -X POST "$RECEIVER_URL/reset" > /dev/null
echo "  Prometheus: http://localhost:9090"
docker compose up -d dbz-logminer 2>/dev/null

echo "  Waiting for LogMiner streaming..."
for i in $(seq 1 90); do
    if docker logs dbz-logminer 2>&1 | tail -20 | grep -q "Starting streaming"; then
        echo "  LogMiner: streaming"
        break
    fi
    if [[ $i -eq 90 ]]; then echo "ERROR: LogMiner timeout" >&2; exit 1; fi
    sleep 2
done

# Start OLR on VM, then adapter (adapter must connect before OLR processes)
# OLR needs RAC public network to reach SCAN VIPs and redo log shares
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
sleep 2
docker compose up -d dbz-olr 2>/dev/null

echo "  Waiting for OLR..."
for i in $(seq 1 90); do
    if ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" \
        "podman logs $OLR_CONTAINER 2>&1 | grep -q 'processing redo log'" 2>/dev/null; then
        echo "  OLR + adapter: ready"
        break
    fi
    if [[ $i -eq 90 ]]; then echo "ERROR: OLR timeout" >&2; exit 1; fi
    sleep 2
done
sleep 5
cd - > /dev/null
echo ""

# ---- Stage 2: Run Swingbench ----
echo "--- Stage 2: Swingbench (${SB_USERS} users, ${DURATION}s) ---"

"$CHARBENCH" \
    -cs //${VM_HOST}:1521/ORCLPDB \
    -u soe -p soe \
    -c "$SB_CONFIG" \
    -uc "$SB_USERS" \
    -rt "$SB_RT" \
    -nc -nr \
    -v users,tps,dml,resp 2>&1 &
SB_PID=$!

POLL_START=$(date +%s)
while kill -0 $SB_PID 2>/dev/null; do
    ELAPSED=$(( $(date +%s) - POLL_START ))
    _print_metrics "  [${ELAPSED}s]"
    sleep 10
done
wait $SB_PID || true

echo ""
echo "  Swingbench completed in $(( $(date +%s) - POLL_START ))s"
echo ""

# ---- Stage 3: Wait for adapters to catch up ----
echo "--- Stage 3: Wait for adapters to catch up (120s max) ---"
WAIT_START=$(date +%s)
LAST_LM=0
LAST_OLR=0
STALL_COUNT=0

while true; do
    ELAPSED=$(( $(date +%s) - WAIT_START ))
    if [[ $ELAPSED -ge 120 ]]; then
        echo "  Time limit reached"
        break
    fi

    DATA=$(_poll_metrics)
    CUR_LM=$(echo "$DATA" | python3 -c "import json,sys; print(json.load(sys.stdin).get('logminer',{}).get('count',0))" 2>/dev/null || echo 0)
    CUR_OLR=$(echo "$DATA" | python3 -c "import json,sys; print(json.load(sys.stdin).get('olr',{}).get('count',0))" 2>/dev/null || echo 0)

    if [[ "$CUR_LM" == "$LAST_LM" && "$CUR_OLR" == "$LAST_OLR" ]]; then
        STALL_COUNT=$(( STALL_COUNT + 1 ))
    else
        STALL_COUNT=0
    fi
    LAST_LM="$CUR_LM"
    LAST_OLR="$CUR_OLR"

    if [[ $STALL_COUNT -ge 3 && "$CUR_LM" -gt 0 && "$CUR_OLR" -gt 0 ]]; then
        echo "  Both adapters caught up"
        break
    fi

    _print_metrics "  [${ELAPSED}s]"
    sleep 10
done
echo ""

# ---- Stage 4: Results ----
echo "--- Stage 4: Results ---"
FINAL=$(_poll_metrics)
echo "$FINAL" | python3 -c "
import json, sys

d = json.load(sys.stdin)

print('=' * 80)
print(f'{\"Metric\":30s} {\"LogMiner\":>20s} {\"OLR\":>20s}')
print('=' * 80)

lm = d.get('logminer', {})
olr = d.get('olr', {})

rows = [
    ('Events captured',        f'{lm.get(\"count\",0):,}',             f'{olr.get(\"count\",0):,}'),
    ('Throughput (total eps)',  f'{lm.get(\"throughput_total_eps\",0):.1f}', f'{olr.get(\"throughput_total_eps\",0):.1f}'),
    ('Throughput (10s eps)',    f'{lm.get(\"throughput_10s_eps\",0):.1f}',   f'{olr.get(\"throughput_10s_eps\",0):.1f}'),
    ('Latency avg (ms)',       f'{lm.get(\"latency_avg_ms\",0):.1f}',      f'{olr.get(\"latency_avg_ms\",0):.1f}'),
    ('Latency p50 (ms)',       f'{lm.get(\"latency_p50_ms\",0):.1f}',      f'{olr.get(\"latency_p50_ms\",0):.1f}'),
    ('Latency p95 (ms)',       f'{lm.get(\"latency_p95_ms\",0):.1f}',      f'{olr.get(\"latency_p95_ms\",0):.1f}'),
    ('Latency p99 (ms)',       f'{lm.get(\"latency_p99_ms\",0):.1f}',      f'{olr.get(\"latency_p99_ms\",0):.1f}'),
    ('Latency min (ms)',       f'{lm.get(\"latency_min_ms\",0):.1f}',      f'{olr.get(\"latency_min_ms\",0):.1f}'),
    ('Latency max (ms)',       f'{lm.get(\"latency_max_ms\",0):.1f}',      f'{olr.get(\"latency_max_ms\",0):.1f}'),
]

for label, lm_val, olr_val in rows:
    print(f'{label:30s} {lm_val:>20s} {olr_val:>20s}')

print('=' * 80)
"

# Cleanup
cd "$SCRIPT_DIR"
docker compose down -v 2>/dev/null || true
cd - > /dev/null
ssh $_SSH_OPTS "${VM_USER}@${VM_HOST}" "podman rm -f $OLR_CONTAINER 2>/dev/null" > /dev/null || true

echo ""
echo "=== Performance test complete ==="
