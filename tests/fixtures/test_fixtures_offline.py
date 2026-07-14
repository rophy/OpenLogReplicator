"""OLR offline-mode fixture tests (RAC).

Runs OLR in offline mode against captured RAC archive logs with no Oracle
access and online-redo stripped from the checkpoint. Validates that OLR
can discover multi-thread archives by directory scanning alone.
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
            "--user", f"{os.getuid()}:{os.getgid()}",
            "-v", f"{tmp_dir}:/olr-work",
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


def strip_online_redo(src_checkpoint, dst_path):
    """Copy checkpoint with online-redo removed."""
    with open(src_checkpoint) as f:
        data = json.load(f)
    data["online-redo"] = []
    with open(dst_path, "w") as f:
        json.dump(data, f, indent=2)


def stage_archives_for_offline(redo_dir, tmp_dir, context):
    """Create the directory structure offline mode expects.

    Offline scans: <db-recovery-file-dest>/<context>/archivelog/<date-subdir>/
    We stage as:   <tmp>/archivelog-root/<context>/archivelog/day/<files>
    """
    archive_tree = os.path.join(tmp_dir, "archivelog-root", context, "archivelog", "day")
    os.makedirs(archive_tree, exist_ok=True)
    for f in glob.glob(os.path.join(redo_dir, "*")):
        if os.path.isfile(f):
            shutil.copy2(f, archive_tree)
    return os.path.join(tmp_dir, "archivelog-root")


def build_offline_config(tmp_dir, redo_dir, schema_dir):
    """Build OLR config for offline mode with no Oracle access."""
    schema_info = find_schema(schema_dir)
    assert schema_info is not None, f"No schema checkpoint found in {schema_dir}"
    start_scn, schema_file = schema_info

    # Read checkpoint to get context and db-recovery-file-dest
    with open(schema_file) as f:
        checkpoint = json.load(f)
    context = checkpoint.get("context", "")
    db_recovery = checkpoint.get("db-recovery-file-dest", "")

    # Copy checkpoint with online-redo stripped
    stripped_checkpoint = os.path.join(tmp_dir, os.path.basename(schema_file))
    strip_online_redo(schema_file, stripped_checkpoint)

    # Stage archives in offline-expected directory structure
    archive_root = stage_archives_for_offline(redo_dir, tmp_dir, context)

    # Detect archive format
    archive_format = detect_archive_format(redo_dir)

    # Container paths
    container_tmp = "/olr-work"
    container_archive_root = f"{container_tmp}/archivelog-root"
    container_output = f"{container_tmp}/output.json"

    # Build path-mapping: redirect db-recovery-file-dest to our staged root
    # Offline constructs: <db-recovery-file-dest>/<context>/archivelog
    # We map that to:     <container_archive_root>/<context>/archivelog
    path_mapping = []
    if db_recovery:
        path_mapping = [db_recovery, container_archive_root]
    else:
        path_mapping = ["", container_archive_root]

    config = {
        "version": "1.9.0",
        "log-level": 3,
        "memory": {"min-mb": 32, "max-mb": 256},
        "state": {"type": "disk", "path": container_tmp},
        "source": [
            {
                "alias": "S1",
                "name": "TEST",
                "reader": {
                    "type": "offline",
                    "log-archive-format": archive_format,
                    "path-mapping": path_mapping,
                    "start-scn": start_scn,
                },
                "format": {
                    "type": "json",
                    "scn": 1,
                    "timestamp": 7,
                    "timestamp-metadata": 7,
                    "xid": 1,
                    "json-number-type": 1,
                },
                "filter": {
                    "table": [{"owner": "OLR_TEST", "table": ".*"}]
                },
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


def _is_rac_fixture(fixture_name):
    return fixture_name.endswith("-rac")


# Only RAC fixtures
fixture_params = [
    (base, name) for base, name in discover_fixtures() if _is_rac_fixture(name)
]


@pytest.mark.parametrize(
    "base_dir,fixture_name",
    fixture_params,
    ids=[f"{base}/{name}" for base, name in fixture_params],
)
def test_fixture_offline(base_dir, fixture_name, tmp_path):
    """Run OLR in offline mode against a RAC fixture — no Oracle, no online redo."""
    fixture_dir = os.path.join(TESTS_DIR, base_dir, fixture_name)
    redo_dir = os.path.join(fixture_dir, "redo")
    schema_dir = os.path.join(fixture_dir, "schema")
    expected_file = os.path.join(fixture_dir, "expected", "output.json")

    assert os.path.isdir(redo_dir), f"redo logs missing: {redo_dir}"
    assert os.path.isfile(expected_file), f"golden file missing: {expected_file}"

    tmp_dir = str(tmp_path)
    config_path, output_path = build_offline_config(tmp_dir, redo_dir, schema_dir)

    result = _run_olr(config_path, tmp_dir)
    assert result.returncode == 0, (
        f"OLR exited with error (rc={result.returncode})\n"
        f"stdout:\n{result.stdout[-3000:]}\n"
        f"stderr:\n{result.stderr[-3000:]}"
    )
    assert os.path.isfile(output_path), (
        f"OLR did not produce output file\n"
        f"stdout:\n{result.stdout[-3000:]}\n"
        f"stderr:\n{result.stderr[-3000:]}"
    )

    with open(expected_file) as f:
        expected = f.read()
    with open(output_path) as f:
        actual = f.read()

    assert actual == expected, (
        f"Output differs from golden file\n"
        f"Expected: {expected_file}\n"
        f"Actual: {output_path}"
    )
