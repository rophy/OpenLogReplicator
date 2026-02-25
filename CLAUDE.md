# OpenLogReplicator

## Build

Prerequisites: Docker, docker compose, and `OpenLogReplicator-docker` cloned as `./OpenLogReplicator-docker/`.

```bash
# Release build
GIDOLR=$(id -g) UIDOLR=$(id -u) docker compose run --rm build ./build-prod.sh

# Debug build
GIDOLR=$(id -g) UIDOLR=$(id -u) docker compose run --rm build ./build-dev.sh
```

The `docker-compose.yaml` mounts the source tree into the docker build context at
the path the Dockerfile expects (`OpenLogReplicator/`), and mounts the Docker socket
so `docker build` runs against the host daemon. No source copying needed.
