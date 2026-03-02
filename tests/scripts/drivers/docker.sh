#!/usr/bin/env bash
# Driver: docker
# Oracle via docker exec, OLR via docker compose exec.
# This is the default driver. Used when ORACLE_DRIVER=docker (or unset).
#
# Additional env vars (optional):
#   ORACLE_CONTAINER — Docker container running Oracle (default: oracle)
#   DOCKER_EXEC_USER — User for docker exec (set to "oracle" for official images)

: "${ORACLE_CONTAINER:=oracle}"

_DEXEC="docker exec"
if [[ -n "${DOCKER_EXEC_USER:-}" ]]; then
    _DEXEC="docker exec -u $DOCKER_EXEC_USER"
fi

_CONTAINER_TESTS="/opt/OpenLogReplicator-local/tests"
_OLR_BINARY="/opt/OpenLogReplicator/OpenLogReplicator"

# Validate environment directory and set COMPOSE
[[ -d "$ENV_DIR" ]] || { echo "ERROR: Environment directory not found: $ENV_DIR" >&2; exit 1; }
COMPOSE="docker compose -f $ENV_DIR/docker-compose.yaml"

# Run SQL as sysdba; returns stdout
exec_sysdba() {
    local sql_file="$1"
    local remote="/tmp/$(basename "$sql_file")"
    docker cp "$sql_file" "${ORACLE_CONTAINER}:${remote}"
    $_DEXEC "$ORACLE_CONTAINER" sqlplus -S / as sysdba @"$remote"
}

# Run SQL as test user; returns stdout
exec_user() {
    local sql_file="$1"
    local remote="/tmp/$(basename "$sql_file")"
    docker cp "$sql_file" "${ORACLE_CONTAINER}:${remote}"
    $_DEXEC "$ORACLE_CONTAINER" sqlplus -S "$DB_CONN" @"$remote"
}

# Path for SPOOL directive (inside Oracle container filesystem)
oracle_spool_path() {
    echo "/tmp/olr_spool.lst"
}

# Copy spool output back to a local file
fetch_spool() {
    docker cp "${ORACLE_CONTAINER}:/tmp/olr_spool.lst" "$1"
}

# Copy an archive log from Oracle container to a local path
fetch_archive() {
    docker cp "${ORACLE_CONTAINER}:$1" "$2"
}

# Convert a host-side absolute path to the OLR-visible path inside its container
# (tests/ is bind-mounted at _CONTAINER_TESTS in the olr compose service)
olr_path() {
    echo "${_CONTAINER_TESTS}/${1#$TESTS_DIR/}"
}

# Run OLR with the given config file (host path); caller redirects stdout/stderr
run_olr() {
    local host_config="$1"
    $COMPOSE exec -T olr \
        "$_OLR_BINARY" -r -f "$(olr_path "$host_config")"
}
