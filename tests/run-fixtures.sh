#!/usr/bin/env bash
# run-fixtures.sh — Run OLR in batch mode against redo log fixtures
# and compare output against golden files.
#
# Usage: ./run-fixtures.sh [fixture-name ...]
#   No arguments: auto-discover all fixtures from fixtures/ and sql/generated/
#   With arguments: run only the named fixtures
#
# Environment:
#   OLR_BINARY  — path to OLR binary (default: auto-detect from cmake build dir)
#   TESTS_DIR   — path to tests/ directory (default: directory containing this script)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${TESTS_DIR:-$SCRIPT_DIR}"

# Auto-detect OLR binary
if [[ -z "${OLR_BINARY:-}" ]]; then
    for candidate in \
        /opt/OpenLogReplicator/OpenLogReplicator \
        /opt/OpenLogReplicator-local/cmake-build-Debug-x86_64/OpenLogReplicator \
        "$TESTS_DIR/../cmake-build-Debug-x86_64/OpenLogReplicator" \
        "$TESTS_DIR/../build/OpenLogReplicator"; do
        if [[ -x "$candidate" ]]; then
            OLR_BINARY="$candidate"
            break
        fi
    done
fi
if [[ -z "${OLR_BINARY:-}" ]]; then
    echo "ERROR: OLR binary not found. Set OLR_BINARY env var." >&2
    exit 1
fi

# --- Discover fixtures ---
discover_fixtures() {
    local base_dir="$1" # e.g., fixtures or sql/generated
    local dir="$TESTS_DIR/$base_dir/expected"
    [[ -d "$dir" ]] || return 0
    for scenario_dir in "$dir"/*/; do
        [[ -f "${scenario_dir}output.json" ]] || continue
        echo "$base_dir/$(basename "$scenario_dir")"
    done
}

if [[ $# -gt 0 ]]; then
    FIXTURES=("$@")
else
    FIXTURES=()
    while IFS= read -r f; do
        FIXTURES+=("$f")
    done < <({ discover_fixtures "fixtures"; discover_fixtures "sql/generated"; } | sort)
fi

if [[ ${#FIXTURES[@]} -eq 0 ]]; then
    echo "No fixtures found."
    exit 0
fi

# --- Detect archive format from redo filenames ---
detect_archive_format() {
    local redo_dir="$1"
    local sample
    sample=$(ls "$redo_dir"/* 2>/dev/null | head -1)
    [[ -n "$sample" ]] || { echo "%t_%s_%r.dbf"; return; }
    local fname
    fname=$(basename "$sample")
    local stem="${fname%.*}"
    local ext="${fname##*.}"
    # Expected: [prefix]<thread>_<seq>_<resetlogs>.<ext>
    local resetlogs="${stem##*_}"
    local rest="${stem%_*}"
    local seq="${rest##*_}"
    local prefix_thread="${rest%_*}"
    # prefix_thread is e.g. "arch1" — split into prefix + thread
    local thread="${prefix_thread##*[!0-9]}"
    local prefix="${prefix_thread%$thread}"
    echo "${prefix}%t_%s_%r.${ext}"
}

# --- Find schema checkpoint and extract start SCN ---
find_schema() {
    local schema_dir="$1"
    [[ -d "$schema_dir" ]] || return 1
    local best_file="" best_scn=999999999999
    for f in "$schema_dir"/TEST-chkpt-*.json; do
        [[ -f "$f" ]] || continue
        local fname
        fname=$(basename "$f")
        # Extract SCN from TEST-chkpt-<scn>.json
        local scn="${fname#TEST-chkpt-}"
        scn="${scn%.json}"
        if [[ "$scn" -lt "$best_scn" ]] 2>/dev/null; then
            best_scn="$scn"
            best_file="$f"
        fi
    done
    [[ -n "$best_file" ]] || return 1
    echo "$best_scn $best_file"
}

# --- Run one fixture ---
run_fixture() {
    local fixture="$1"
    local scenario="${fixture##*/}"
    local dir_prefix="${fixture%/*}"

    case "$dir_prefix" in
        fixtures|sql/generated) ;;
        *) echo "FAIL  $fixture (unknown prefix: $dir_prefix)"; return 1 ;;
    esac

    local redo_dir="$TESTS_DIR/$dir_prefix/redo/$scenario"
    local schema_dir="$TESTS_DIR/$dir_prefix/schema/$scenario"
    local expected="$TESTS_DIR/$dir_prefix/expected/$scenario/output.json"

    if [[ ! -d "$redo_dir" ]]; then
        echo "FAIL  $fixture (redo logs missing: $redo_dir)"
        return 1
    fi

    # Temp dir for this test
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Collect redo log files
    local redo_json="["
    local first=1
    for f in "$redo_dir"/*; do
        [[ -f "$f" ]] || continue
        [[ $first -eq 1 ]] && first=0 || redo_json+=", "
        redo_json+="\"$f\""
    done
    redo_json+="]"

    local archive_format
    archive_format=$(detect_archive_format "$redo_dir")

    # Schema detection
    local reader_extra="" flags_line="" filter_section=""
    local schema_info
    if schema_info=$(find_schema "$schema_dir"); then
        local start_scn="${schema_info%% *}"
        local schema_file="${schema_info#* }"
        cp "$schema_file" "$tmp_dir/"
        reader_extra=$(printf ',\n        "log-archive-format": "%s",\n        "start-scn": %s' "$archive_format" "$start_scn")
        filter_section=',
      "filter": {
        "table": [
          {"owner": "OLR_TEST", "table": ".*"}
        ]
      }'
    else
        reader_extra=$(printf ',\n        "log-archive-format": ""')
        flags_line=',
      "flags": 2'
    fi

    local output="$tmp_dir/output.json"

    cat > "$tmp_dir/config.json" <<EOF
{
  "version": "1.9.0",
  "log-level": 3,
  "memory": {
    "min-mb": 32,
    "max-mb": 256
  },
  "state": {
    "type": "disk",
    "path": "$tmp_dir"
  },
  "source": [
    {
      "alias": "S1",
      "name": "TEST",
      "reader": {
        "type": "batch",
        "redo-log": $redo_json$reader_extra
      },
      "format": {
        "type": "json",
        "scn": 1,
        "timestamp": 7,
        "timestamp-metadata": 7,
        "xid": 1
      }$flags_line$filter_section
    }
  ],
  "target": [
    {
      "alias": "T1",
      "source": "S1",
      "writer": {
        "type": "file",
        "output": "$output",
        "new-line": 1,
        "append": 1
      }
    }
  ]
}
EOF

    # Run OLR
    local olr_log="$tmp_dir/olr.log"
    if ! "$OLR_BINARY" -r -f "$tmp_dir/config.json" > "$olr_log" 2>&1; then
        echo "FAIL  $fixture (OLR exited with error)"
        cat "$olr_log" >&2
        return 1
    fi

    if [[ ! -f "$output" ]]; then
        echo "FAIL  $fixture (no output file)"
        cat "$olr_log" >&2
        return 1
    fi

    # Compare against golden file
    local diff_out
    if diff_out=$(diff --unified "$expected" "$output"); then
        echo "PASS  $fixture"
        return 0
    else
        echo "FAIL  $fixture (output differs)"
        echo "$diff_out" >&2
        return 1
    fi
}

# --- Main ---
passed=0
failed=0
failures=()

echo "Running ${#FIXTURES[@]} fixture(s)..."
echo ""

for fixture in "${FIXTURES[@]}"; do
    if run_fixture "$fixture"; then
        ((passed++)) || true
    else
        ((failed++)) || true
        failures+=("$fixture")
    fi
done

echo ""
echo "Results: $passed passed, $failed failed, $((passed + failed)) total"

if [[ $failed -gt 0 ]]; then
    echo ""
    echo "Failed:"
    for f in "${failures[@]}"; do
        echo "  $f"
    done
    exit 1
fi
