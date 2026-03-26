"""OLR fixture regression tests.

Runs OLR in batch mode against captured redo log fixtures and compares
JSON output against golden files. No Oracle instance needed.
"""

import json
import os
import glob
import shutil
import subprocess

import pytest

from conftest import discover_fixtures

FIXTURES_DIR = os.path.dirname(os.path.abspath(__file__))
TESTS_DIR = os.path.dirname(FIXTURES_DIR)
OLR_IMAGE = os.environ.get("OLR_IMAGE", "olr-dev:latest")


def _run_olr(config_path, tmp_dir):
    """Run OLR binary via docker."""
    return subprocess.run(
        [
            "docker", "run", "--rm",
            "-v", f"{tmp_dir}:/olr-work",
            "-v", f"{TESTS_DIR}:/tests:ro",
            "--entrypoint", "/opt/OpenLogReplicator/OpenLogReplicator",
            OLR_IMAGE,
            "-r", "-f", f"/olr-work/{os.path.basename(config_path)}",
        ],
        capture_output=True,
        text=True,
    )


def detect_archive_format(redo_dir):
    """Detect log-archive-format from redo filenames."""
    files = sorted(f for f in glob.glob(os.path.join(redo_dir, "*")) if os.path.isfile(f))
    if not files:
        return "%t_%s_%r.dbf"
    fname = os.path.basename(files[0])
    stem, ext = os.path.splitext(fname)
    parts = stem.rsplit("_", 2)
    if len(parts) < 3:
        return "%t_%s_%r" + ext
    prefix_thread = parts[0]
    i = len(prefix_thread)
    while i > 0 and prefix_thread[i - 1].isdigit():
        i -= 1
    prefix = prefix_thread[:i]
    return f"{prefix}%t_%s_%r{ext}"


def find_schema(schema_dir):
    """Find schema checkpoint file and return (scn, path)."""
    if not os.path.isdir(schema_dir):
        return None
    best_scn = None
    best_file = None
    for f in glob.glob(os.path.join(schema_dir, "TEST-chkpt-*.json")):
        fname = os.path.basename(f)
        scn_str = fname.removeprefix("TEST-chkpt-").removesuffix(".json")
        try:
            scn = int(scn_str)
        except ValueError:
            continue
        if best_scn is None or scn < best_scn:
            best_scn = scn
            best_file = f
    if best_file is None:
        return None
    return best_scn, best_file


def build_config(tmp_dir, redo_dir, schema_dir, base_dir, fixture_name):
    """Build OLR config JSON. Paths use /tests/ (container mount)."""
    # Container paths
    container_tests = "/tests"
    container_redo = f"{container_tests}/{base_dir}/{fixture_name}/redo"
    container_tmp = "/olr-work"
    container_output = f"{container_tmp}/output.json"

    # Detect archive format from host paths
    archive_format = detect_archive_format(redo_dir)

    # List redo files using host paths, convert to container paths
    redo_files = sorted(f for f in glob.glob(os.path.join(redo_dir, "*")) if os.path.isfile(f))
    container_redo_files = [
        f"{container_redo}/{os.path.basename(f)}" for f in redo_files
    ]

    schema_info = find_schema(schema_dir)
    if schema_info:
        start_scn, schema_file = schema_info
        shutil.copy2(schema_file, tmp_dir)
        reader = {
            "type": "batch",
            "redo-log": container_redo_files,
            "log-archive-format": archive_format,
            "start-scn": start_scn,
        }
        source_extra = {
            "filter": {"table": [{"owner": "OLR_TEST", "table": ".*"}]}
        }
    else:
        reader = {
            "type": "batch",
            "redo-log": container_redo_files,
            "log-archive-format": "",
        }
        source_extra = {"flags": 2}

    config = {
        "version": "1.9.0",
        "log-level": 3,
        "memory": {"min-mb": 32, "max-mb": 256},
        "state": {"type": "disk", "path": container_tmp},
        "source": [
            {
                "alias": "S1",
                "name": "TEST",
                "reader": reader,
                "format": {
                    "type": "json",
                    "scn": 1,
                    "timestamp": 7,
                    "timestamp-metadata": 7,
                    "xid": 1,
                    "json-number-type": 1,
                },
                **source_extra,
            }
        ],
        "target": [
            {
                "alias": "T1",
                "source": "S1",
                "writer": {
                    "type": "file",
                    "output": container_output,
                    "new-line": 1,
                    "append": 1,
                },
            }
        ],
    }

    config_path = os.path.join(tmp_dir, "config.json")
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)

    output_path = os.path.join(tmp_dir, "output.json")
    return config_path, output_path


# Parametrize: each discovered fixture becomes a test case
fixture_params = discover_fixtures()


@pytest.mark.parametrize(
    "base_dir,fixture_name",
    fixture_params,
    ids=[f"{base}/{name}" for base, name in fixture_params],
)
def test_fixture(base_dir, fixture_name, tmp_path):
    """Run OLR against a fixture and compare output to golden file."""
    fixture_dir = os.path.join(TESTS_DIR, base_dir, fixture_name)
    redo_dir = os.path.join(fixture_dir, "redo")
    schema_dir = os.path.join(fixture_dir, "schema")
    expected_file = os.path.join(fixture_dir, "expected", "output.json")

    assert os.path.isdir(redo_dir), f"redo logs missing: {redo_dir}"
    assert os.path.isfile(expected_file), f"golden file missing: {expected_file}"

    tmp_dir = str(tmp_path)
    config_path, output_path = build_config(
        tmp_dir, redo_dir, schema_dir, base_dir, fixture_name
    )

    # Run OLR via docker
    result = _run_olr(config_path, tmp_dir)
    assert result.returncode == 0, (
        f"OLR exited with error (rc={result.returncode})\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )
    assert os.path.isfile(output_path), (
        f"OLR did not produce output file\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )

    # Compare output
    with open(expected_file) as f:
        expected = f.read()
    with open(output_path) as f:
        actual = f.read()

    assert actual == expected, (
        f"Output differs from golden file\n"
        f"Expected: {expected_file}\n"
        f"Actual: {output_path}"
    )
