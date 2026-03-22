#!/bin/bash
# RAC VM is managed externally — verify it's reachable and configs match.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SSH_KEY="$PROJECT_ROOT/oracle-rac/assets/vm-key"

# Auto-detect VM IP from virsh
ACTUAL_IP=$(virsh domifaddr oracle-rac-vm 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1)
if [[ -z "$ACTUAL_IP" ]]; then
    echo "ERROR: Cannot detect RAC VM IP. Is oracle-rac-vm running?" >&2
    echo "  Start with: virsh start oracle-rac-vm" >&2
    exit 1
fi

# Check that config files match the actual IP
MISMATCH=0
_check_ip() {
    local file="$1"
    if [[ -f "$file" ]]; then
        # Skip comments (lines starting with # or //) and check remaining lines
        local found
        found=$(grep -v '^\s*#\|^\s*//' "$file" | grep -oP '192\.168\.122\.\d+' | sort -u || true)
        for ip in $found; do
            if [[ "$ip" != "$ACTUAL_IP" ]]; then
                echo "  MISMATCH: $file has $ip (expected $ACTUAL_IP)" >&2
                MISMATCH=1
            fi
        done
    fi
}

_check_ip "$SCRIPT_DIR/.env"
_check_ip "$SCRIPT_DIR/../../../sql/scripts/drivers/rac.sh"
_check_ip "$SCRIPT_DIR/debezium/config/application-logminer.properties"
_check_ip "$SCRIPT_DIR/debezium/config/application-olr.properties"
_check_ip "$SCRIPT_DIR/debezium/config/olr-config.json"

if [[ $MISMATCH -ne 0 ]]; then
    echo "ERROR: RAC VM IP is $ACTUAL_IP but config files have stale IPs." >&2
    echo "  Fix with: sed -i 's/192.168.122.[0-9]\\+/$ACTUAL_IP/g' <files above>" >&2
    exit 1
fi

export VM_HOST="$ACTUAL_IP"
echo "RAC VM IP: $ACTUAL_IP"
echo "Checking RAC VM connectivity..."
ssh -o ConnectTimeout=5 -o BatchMode=yes -i "$SSH_KEY" root@$ACTUAL_IP "echo 'RAC VM is reachable'" || {
    echo "ERROR: Cannot reach RAC VM at $ACTUAL_IP" >&2
    exit 1
}
