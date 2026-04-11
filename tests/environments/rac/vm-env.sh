#!/bin/bash
# Shared RAC VM environment — source this from any RAC test script.
# Auto-detects VM IP via virsh and validates config files.
#
# Usage: source "$(dirname "$0")/vm-env.sh"  (or path to this file)
#
# Exports: VM_HOST, VM_KEY, VM_USER, _SSH_OPTS

_RAC_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_RAC_ENV_DIR/../../.." && pwd)"

VM_KEY="${VM_KEY:-$_PROJECT_ROOT/oracle-rac/assets/vm-key}"
VM_USER="${VM_USER:-root}"

# Auto-detect VM IP from virsh (filter for libvirt 192.168.122.* subnet, take first)
if [[ -z "${VM_HOST:-}" ]]; then
    VM_HOST=$(virsh domifaddr oracle-rac-vm 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | grep '^192\.168\.122\.' | head -1)
    if [[ -z "$VM_HOST" ]]; then
        echo "ERROR: Cannot detect RAC VM IP. Is oracle-rac-vm running?" >&2
        echo "  Start with: virsh start oracle-rac-vm" >&2
        return 1 2>/dev/null || exit 1
    fi
fi

_SSH_OPTS="-i $VM_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

export VM_HOST VM_KEY VM_USER _SSH_OPTS
