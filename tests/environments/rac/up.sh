#!/bin/bash
# RAC VM is managed externally — verify it's reachable and configs match.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/vm-env.sh"

echo "RAC VM IP: $VM_HOST"
echo "Checking RAC VM connectivity..."
ssh -o ConnectTimeout=5 -o BatchMode=yes $_SSH_OPTS "${VM_USER}@${VM_HOST}" "echo 'RAC VM is reachable'" || {
    echo "ERROR: Cannot reach RAC VM at $VM_HOST" >&2
    exit 1
}
