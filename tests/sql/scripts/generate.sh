#!/usr/bin/env bash
# generate.sh — Generate + validate one OLR regression test fixture.
#
# Usage: ./generate.sh <scenario-name>
# Example: ./generate.sh basic-crud
#
# Runs SQL against an Oracle instance, captures redo logs, generates schema,
# runs LogMiner + OLR, and compares output.
#
# Works with both single-node (.sql) and RAC (.rac.sql) scenarios.
# The driver determines how Oracle is accessed and how OLR runs.
#
# Prerequisites:
#   - Oracle accessible via the selected driver (default: docker)
#   - For docker driver: containers running via docker compose up in tests/environments/$ORACLE_TARGET
#
# Environment variables:
#   ORACLE_DRIVER    — Driver to use: docker (default), local, or rac
#                      See tests/scripts/drivers/ for driver-specific env vars
#   ORACLE_TARGET    — Oracle environment name (default: free-23)
#                      Used by docker driver to locate docker-compose.yaml
#   DB_CONN          — sqlplus connect string for test user
#                      (default: olr_test/olr_test@//localhost:1521/FREEPDB1)
#   SCHEMA_OWNER     — Schema owner for LogMiner filter (default: OLR_TEST)
#   PDB_NAME         — PDB service name (default: FREEPDB1)
#   OUTPUT_BASE      — Output directory (default: $SQL_DIR/generated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$(cd "$SQL_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Oracle target environment (used by docker driver)
ORACLE_TARGET="${ORACLE_TARGET:-free-23}"
ENV_DIR="$TESTS_DIR/environments/$ORACLE_TARGET"

# Source environment .env file if present (provides DB_CONN, PDB_NAME, etc.)
if [[ -f "$ENV_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_DIR/.env"
    set +a
fi

# Defaults (only applied if not set by .env or caller)
DB_CONN="${DB_CONN:-olr_test/olr_test@//localhost:1521/FREEPDB1}"
SCHEMA_OWNER="${SCHEMA_OWNER:-OLR_TEST}"
PDB_NAME="${PDB_NAME:-FREEPDB1}"

# Parse scenario name early (drivers may reference it during source)
SCENARIO="${1:?Usage: $0 <scenario-name>}"

# Source the driver (which sources base.sh, defines primitives + stage functions)
ORACLE_DRIVER="${ORACLE_DRIVER:-docker}"
DRIVER_FILE="$SCRIPT_DIR/drivers/${ORACLE_DRIVER}.sh"
[[ -f "$DRIVER_FILE" ]] || { echo "ERROR: Unknown driver '$ORACLE_DRIVER' (no $DRIVER_FILE)" >&2; exit 1; }
# shellcheck source=/dev/null
source "$DRIVER_FILE"

# Detect input format: single file (.sql/.rac.sql) or directory (setup.sql + test.sql)
INPUTS_DIR="$SQL_DIR/inputs"
HAS_FILE=0
HAS_DIR=0
[[ -f "$INPUTS_DIR/${SCENARIO}.sql" ]] || [[ -f "$INPUTS_DIR/${SCENARIO}.rac.sql" ]] && HAS_FILE=1
[[ -d "$INPUTS_DIR/${SCENARIO}" ]] && [[ -f "$INPUTS_DIR/${SCENARIO}/test.sql" ]] && HAS_DIR=1

# Conflict check
if [[ "$HAS_FILE" -eq 1 ]] && [[ "$HAS_DIR" -eq 1 ]]; then
    echo "ERROR: Conflicting inputs for '$SCENARIO':" >&2
    echo "  Found both file and directory:" >&2
    [[ -f "$INPUTS_DIR/${SCENARIO}.sql" ]] && echo "    $INPUTS_DIR/${SCENARIO}.sql" >&2
    [[ -f "$INPUTS_DIR/${SCENARIO}.rac.sql" ]] && echo "    $INPUTS_DIR/${SCENARIO}.rac.sql" >&2
    echo "    $INPUTS_DIR/${SCENARIO}/" >&2
    echo "  Remove one to resolve the conflict." >&2
    exit 1
fi

if [[ "$HAS_DIR" -eq 1 ]]; then
    # Split mode: setup.sql (optional) + test.sql (required)
    SCENARIO_MODE=split
    SETUP_SQL=""
    [[ -f "$INPUTS_DIR/${SCENARIO}/setup.sql" ]] && SETUP_SQL="$INPUTS_DIR/${SCENARIO}/setup.sql"
    SCENARIO_SQL="$INPUTS_DIR/${SCENARIO}/test.sql"
elif [[ "$HAS_FILE" -eq 1 ]]; then
    # Single-file mode
    SCENARIO_MODE=single
    SCENARIO_SQL="$INPUTS_DIR/${SCENARIO}.sql"
    if [[ ! -f "$SCENARIO_SQL" ]]; then
        SCENARIO_SQL="$INPUTS_DIR/${SCENARIO}.rac.sql"
    fi
else
    echo "ERROR: Scenario not found for: $SCENARIO" >&2
    echo "Looked for:" >&2
    echo "  $INPUTS_DIR/${SCENARIO}.sql" >&2
    echo "  $INPUTS_DIR/${SCENARIO}.rac.sql" >&2
    echo "  $INPUTS_DIR/${SCENARIO}/test.sql" >&2
    echo "Available scenarios:" >&2
    { ls "$INPUTS_DIR/"*.sql "$INPUTS_DIR/"*.rac.sql 2>/dev/null | sed 's/.*\//  /' | sed 's/\.rac\.sql$//;s/\.sql$//';
      find "$INPUTS_DIR" -mindepth 2 -name 'test.sql' 2>/dev/null | sed "s|$INPUTS_DIR/||;s|/test.sql||;s/^/  /"; } | sort -u >&2
    exit 1
fi

# ---- Tag filtering ----
# Check tags in all scenario SQL files
TAG_FILES="$SCENARIO_SQL"
[[ -n "${SETUP_SQL:-}" ]] && TAG_FILES="$SETUP_SQL $SCENARIO_SQL"
SCENARIO_TAGS=$(grep '^-- @TAG ' $TAG_FILES 2>/dev/null | sed 's/.*-- @TAG //' || true)
if [[ -n "$SCENARIO_TAGS" ]]; then
    if [[ -z "${INCLUDE_TAGS:-}" ]]; then
        echo "SKIP: $SCENARIO has tags ($SCENARIO_TAGS) but INCLUDE_TAGS not set"
        exit 0
    fi
    TAG_MATCH=0
    for tag in $SCENARIO_TAGS; do
        for inc in ${INCLUDE_TAGS:-}; do
            [[ "$tag" == "$inc" ]] && TAG_MATCH=1
        done
    done
    if [[ $TAG_MATCH -eq 0 ]]; then
        echo "SKIP: $SCENARIO tags ($SCENARIO_TAGS) not in INCLUDE_TAGS ($INCLUDE_TAGS)"
        exit 0
    fi
fi
for tag in ${SCENARIO_TAGS:-}; do
    for exc in ${EXCLUDE_TAGS:-}; do
        if [[ "$tag" == "$exc" ]]; then
            echo "SKIP: $SCENARIO tag '$tag' is in EXCLUDE_TAGS"
            exit 0
        fi
    done
done

# ---- Setup ----
FIXTURE_NAME="${SCENARIO}${FIXTURE_SUFFIX}"
OUTPUT_BASE="${OUTPUT_BASE:-$SQL_DIR/generated}"

# Working directory (under tests/.work/ so it's visible inside OLR containers)
mkdir -p "$TESTS_DIR/.work"
WORK_DIR=$(mktemp -d "$TESTS_DIR/.work/${ORACLE_TARGET}_${SCENARIO}_XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

# Check for DDL marker
DDL_MODE=0
if grep -q '^-- @DDL' $TAG_FILES 2>/dev/null; then
    DDL_MODE=1
fi

# Check for @MID_SWITCH markers
MID_SWITCH_COUNT=$(grep -c '^-- @MID_SWITCH' $TAG_FILES 2>/dev/null || true)

echo "=== Fixture generation: $SCENARIO (target: $ORACLE_TARGET, driver: $ORACLE_DRIVER) ==="
echo "  Fixture name: $FIXTURE_NAME"
echo "  Work dir: $WORK_DIR"
echo "  Input mode: $SCENARIO_MODE"
if [[ "$DDL_MODE" -eq 1 ]]; then
    echo "  Mode: DDL (DICT_FROM_REDO_LOGS)"
fi
echo ""

# ---- Run stages ----

# Stage 0 (DDL only): Build LogMiner dictionary into redo logs
if [[ "$DDL_MODE" -eq 1 ]]; then
    stage_build_dictionary
fi

# Stage 1: Run SQL scenario
stage_run_scenario

# Stage 2: Capture archived redo logs
stage_capture_archives

# Stage 3: Generate schema file
stage_generate_schema

# Stage 4: Run LogMiner extraction
stage_run_logminer

# Stage 5: Run OLR in batch mode
stage_run_olr

# ---- Stage 6: Compare ----
echo ""
echo "--- Stage 6: Comparing LogMiner vs OLR ---"
if python3 "$SCRIPT_DIR/compare.py" "$WORK_DIR/logminer.json" "$OLR_OUTPUT"; then
    COMPARE_RESULT=0
else
    COMPARE_RESULT=1
fi

# ---- Stage 7: Save golden file ----
echo ""
echo "--- Stage 7: Saving golden file ---"
EXPECTED_DIR="$OUTPUT_BASE/$FIXTURE_NAME/expected"
mkdir -p "$EXPECTED_DIR"
cp "$OLR_OUTPUT" "$EXPECTED_DIR/output.json"
echo "  Golden file saved: $EXPECTED_DIR/output.json"

cp "$WORK_DIR/logminer.json" "$EXPECTED_DIR/logminer-reference.json"
echo "  LogMiner reference saved: $EXPECTED_DIR/logminer-reference.json"

if [[ $COMPARE_RESULT -eq 0 ]]; then
    echo ""
    echo "=== PASS: Fixture '$SCENARIO' generated successfully ==="
else
    echo ""
    echo "=== WARN: Fixture '$SCENARIO' saved with LogMiner comparison differences ==="
    echo "  LogMiner JSON: $WORK_DIR/logminer.json"
    echo "  OLR output:    $OLR_OUTPUT"
    trap - EXIT  # preserve work dir for debugging
    exit 1
fi
