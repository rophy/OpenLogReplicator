#!/bin/bash
# Shared RAC VM environment — source this from any RAC test script.
# Auto-detects VM IP via virsh and validates config files.
#
# Usage: source "$(dirname "$0")/vm-env.sh"  (or path to this file)
#
# Exports: VM_HOST, VM_KEY, VM_USER, _SSH_OPTS

_RAC_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_RAC_ENV_DIR/../../../.." && pwd)"

VM_KEY="${VM_KEY:-$_PROJECT_ROOT/oracle-rac/assets/vm-key}"
VM_USER="${VM_USER:-root}"

# Auto-detect VM IP from virsh (take first IPv4 only)
if [[ -z "${VM_HOST:-}" ]]; then
    VM_HOST=$(virsh domifaddr oracle-rac-vm 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
    if [[ -z "$VM_HOST" ]]; then
        echo "ERROR: Cannot detect RAC VM IP. Is oracle-rac-vm running?" >&2
        echo "  Start with: virsh start oracle-rac-vm" >&2
        return 1 2>/dev/null || exit 1
    fi
fi

_SSH_OPTS="-i $VM_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Validate config files match detected IP
_VM_ENV_MISMATCH=0
_check_ip() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local found
        found=$(grep -v '^\s*#\|^\s*//' "$file" | grep -oP '192\.168\.122\.\d+' | sort -u || true)
        for ip in $found; do
            if [[ "$ip" != "$VM_HOST" ]]; then
                echo "  MISMATCH: $file has $ip (expected $VM_HOST)" >&2
                _VM_ENV_MISMATCH=1
            fi
        done
    fi
}

_check_ip "$_RAC_ENV_DIR/.env"
_check_ip "$_PROJECT_ROOT/tests/sql/scripts/drivers/rac.sh"
_check_ip "$_RAC_ENV_DIR/debezium/config/application-logminer.properties"
_check_ip "$_RAC_ENV_DIR/debezium/config/application-olr.properties"
_check_ip "$_RAC_ENV_DIR/debezium/config/olr-config.json"

if [[ $_VM_ENV_MISMATCH -ne 0 ]]; then
    echo "ERROR: RAC VM IP is $VM_HOST but config files have stale IPs." >&2
    echo "  Fix with: sed -i 's/192.168.122.[0-9]\\+/$VM_HOST/g' <files above>" >&2
    return 1 2>/dev/null || exit 1
fi

export VM_HOST VM_KEY VM_USER _SSH_OPTS
