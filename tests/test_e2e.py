"""End-to-end tests — runs generate.sh per scenario against a live Oracle."""

import os
import subprocess

import pytest

from conftest import discover_scenarios

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
GENERATE_SH = os.path.join(TESTS_DIR, "sql", "scripts", "generate.sh")


def _load_env_file(env_dir):
    """Load KEY=VALUE pairs from .env file into os.environ."""
    env_file = os.path.join(env_dir, ".env")
    if not os.path.isfile(env_file):
        return
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            if key and _ == "=":
                os.environ.setdefault(key, value)


@pytest.fixture(scope="session", autouse=True)
def oracle_lifecycle(oracle_env):
    """Start Oracle environment before tests, stop after."""
    env_dir = os.path.join(TESTS_DIR, "environments", oracle_env)
    _load_env_file(env_dir)

    up_script = os.path.join(env_dir, "up.sh")
    down_script = os.path.join(env_dir, "down.sh")

    if os.path.isfile(up_script):
        subprocess.run([up_script], cwd=env_dir, check=True)
    elif os.path.isfile(os.path.join(env_dir, "docker-compose.yaml")):
        subprocess.run(
            ["docker", "compose", "up", "-d", "--wait"], cwd=env_dir, check=True,
        )

    yield

    if os.path.isfile(down_script):
        subprocess.run([down_script], cwd=env_dir)
    elif os.path.isfile(os.path.join(env_dir, "docker-compose.yaml")):
        subprocess.run(["docker", "compose", "down"], cwd=env_dir)


def pytest_generate_tests(metafunc):
    if "scenario" in metafunc.fixturenames:
        metafunc.parametrize("scenario", discover_scenarios())


def test_e2e(scenario, oracle_env, oracle_driver):
    """Run generate.sh for one scenario and assert it passes."""
    env = {
        **os.environ,
        "ORACLE_TARGET": oracle_env,
        "ORACLE_DRIVER": oracle_driver,
    }

    result = subprocess.run(
        [GENERATE_SH, scenario],
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
    )

    # generate.sh exits 0 for both PASS and SKIP (tagged scenarios)
    if result.returncode == 0:
        if "SKIP:" in result.stdout:
            pytest.skip(result.stdout.strip().split("\n")[-1])
        return

    # Failure — show output for debugging
    msg = f"generate.sh failed for {scenario} (exit {result.returncode})\n"
    if result.stdout:
        msg += f"\n--- stdout ---\n{result.stdout[-2000:]}"
    if result.stderr:
        msg += f"\n--- stderr ---\n{result.stderr[-2000:]}"
    pytest.fail(msg)
