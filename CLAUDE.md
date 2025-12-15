# OpenLogReplicator

## Tutorials

The tutorials are added as a git submodule from https://github.com/rophy/OpenLogReplicator-tutorials.git:

```bash
git submodule add https://github.com/rophy/OpenLogReplicator-tutorials.git tutorials
```

### Oracle-to-file Tutorial

The tutorial at `tutorials/tutorials/Oracle-to-file/` requires two Docker images that take a long time to build from scratch. Pre-built images are available on Docker Hub:

| Original Image | Pre-built Image |
|----------------|-----------------|
| `oracle/database:21.3.0-xe` | `rophy/oracle-database:21.3.0-xe` |
| `bersler/openlogreplicator:tutorial` | `rophy/openlogreplicator:tutorial` |

#### Quick Setup (Recommended)

Pull and retag the pre-built images instead of building from scratch:

```bash
# Pull pre-built images from Docker Hub
docker pull rophy/oracle-database:21.3.0-xe
docker pull rophy/openlogreplicator:tutorial

# Retag to expected names
docker tag rophy/oracle-database:21.3.0-xe oracle/database:21.3.0-xe
docker tag rophy/openlogreplicator:tutorial bersler/openlogreplicator:tutorial
```

Then proceed with step 1 of the tutorial (`./1.check.sh`).

#### Building from Scratch

If you need to build the images yourself, refer to `tutorials/images/README.md`. Note that building takes significant time:
- Oracle 21.3 XE: ~16 minutes
- OpenLogReplicator: ~46 minutes
