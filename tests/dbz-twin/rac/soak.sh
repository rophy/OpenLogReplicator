#!/bin/bash
# Soak driver: back-to-back fuzz cycles until DURATION_SEC elapses or a cycle fails.
# Assumes `fuzz-test.sh up` was already run.
set -e
cd "$(dirname "$0")"
source /home/rophy/projects/OpenLogReplicator/tests/environments/rac/vm-env.sh

DURATION_SEC="${DURATION_SEC:-28800}"   # 8h default
CYCLE_MIN="${CYCLE_MIN:-10}"
LOG_DIR="${LOG_DIR:-./soak-logs/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$LOG_DIR"

deadline=$(( $(date +%s) + DURATION_SEC ))
cursor=""
cycle=0

echo "soak start: duration=${DURATION_SEC}s cycle=${CYCLE_MIN}min log_dir=$LOG_DIR" | tee "$LOG_DIR/summary.log"

while [[ $(date +%s) -lt $deadline ]]; do
    cycle=$((cycle + 1))
    num=$(printf "%03d" "$cycle")
    ts=$(date -Iseconds)
    echo "[$ts] cycle $num: run ${CYCLE_MIN}min" | tee -a "$LOG_DIR/summary.log"

    if ! ./fuzz-test.sh run "$CYCLE_MIN" > "$LOG_DIR/cycle-${num}-run.log" 2>&1; then
        echo "[$(date -Iseconds)] cycle $num: RUN FAILED" | tee -a "$LOG_DIR/summary.log"
        exit 1
    fi

    if ! START_CURSOR="$cursor" ./fuzz-test.sh validate > "$LOG_DIR/cycle-${num}-validate.log" 2>&1; then
        echo "[$(date -Iseconds)] cycle $num: VALIDATE FAILED" | tee -a "$LOG_DIR/summary.log"
        tail -40 "$LOG_DIR/cycle-${num}-validate.log" | tee -a "$LOG_DIR/summary.log"
        exit 1
    fi

    new_cursor=$(grep 'final_cursor=' "$LOG_DIR/cycle-${num}-validate.log" | tail -1 | sed 's/.*final_cursor=//')
    summary=$(grep -E "Total validated|Matched|Mismatches|RESULT" "$LOG_DIR/cycle-${num}-validate.log" | tr '\n' ' ')
    echo "[$(date -Iseconds)] cycle $num: cursor=$new_cursor | $summary" | tee -a "$LOG_DIR/summary.log"
    cursor="$new_cursor"
done

echo "[$(date -Iseconds)] soak complete: $cycle cycles" | tee -a "$LOG_DIR/summary.log"
