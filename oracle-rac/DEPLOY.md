# Oracle RAC 23ai (23.26.1.0) Deployment Guide

2-node Oracle RAC on Podman inside a libvirt/QEMU VM.

## Prerequisites (Host)

- libvirt/QEMU installed, user in `libvirt` group
- `xorriso` installed (for cloud-init ISO)
- Docker with Oracle Container Registry credentials
  (login at https://container-registry.oracle.com first via `docker login`)

## Step 1: Prepare Images (Host)

### 1.1 Pull RAC image and save to file

Skip if `oracle-rac/assets/rac-23.26.1.0.tar` already exists locally:

```bash
if [ ! -f oracle-rac/assets/rac-23.26.1.0.tar ]; then
  docker pull container-registry.oracle.com/database/rac:23.26.1.0
  docker save container-registry.oracle.com/database/rac:23.26.1.0 \
    -o oracle-rac/assets/rac-23.26.1.0.tar
fi
```

This is ~14GB. The tar file can be reused across VM recreations.

## Step 2: Create VM

### 2.1 Generate SSH keypair

```bash
ssh-keygen -t ed25519 -f oracle-rac/assets/vm-key -N "" -C "$USER@$(hostname)"
```

### 2.2 Download Oracle Linux 9 cloud image

Skip if `oracle-rac/assets/OL9U7_x86_64-kvm-b269.qcow2` already exists locally:

```bash
if [ ! -f oracle-rac/assets/OL9U7_x86_64-kvm-b269.qcow2 ]; then
  curl -L -o oracle-rac/assets/OL9U7_x86_64-kvm-b269.qcow2 \
    https://yum.oracle.com/templates/OracleLinux/OL9/u7/x86_64/OL9U7_x86_64-kvm-b269.qcow2
fi
```

Note: Check https://yum.oracle.com/oracle-linux-templates.html for the latest URL.
This is ~800MB and is kept as the original base image.

### 2.3 Create cloud-init ISO

The `oracle-rac/assets/cloud-init.yaml` should contain your SSH public key. Then:

```bash
mkdir -p /tmp/cidata
cp oracle-rac/assets/cloud-init.yaml /tmp/cidata/user-data
echo "instance-id: oracle-rac-vm" > /tmp/cidata/meta-data
xorriso -as mkisofs -o oracle-rac/assets/cloud-init.iso \
  -volid cidata -joliet -rock /tmp/cidata/
rm -rf /tmp/cidata
```

### 2.4 Create VM disk and boot VM

Copy the base image (keeps the original clean for future recreations):

```bash
cp oracle-rac/assets/OL9U7_x86_64-kvm-b269.qcow2 oracle-rac/assets/OL9-vm.qcow2
qemu-img resize oracle-rac/assets/OL9-vm.qcow2 250G

virt-install \
  --name oracle-rac-vm \
  --connect qemu:///system \
  --ram 16384 \
  --vcpus 8 \
  --os-variant ol9.0 \
  --disk path=$(pwd)/oracle-rac/assets/OL9-vm.qcow2,format=qcow2 \
  --disk path=$(pwd)/oracle-rac/assets/cloud-init.iso,device=cdrom \
  --network network=default \
  --graphics none \
  --import \
  --noautoconsole
```

### 2.5 Get VM IP and expand disk

```bash
# Wait for VM to boot (~30 seconds), then:
VM_IP=$(virsh -c qemu:///system domifaddr oracle-rac-vm | grep ipv4 | awk '{print $4}' | cut -d/ -f1)
SSH="ssh -i oracle-rac/assets/vm-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$VM_IP"

# Expand disk (OL9 uses LVM)
$SSH "growpart /dev/vda 4 && pvresize /dev/vda4 && lvextend -l +100%FREE /dev/mapper/vg_main-lv_root && xfs_growfs /"
```

### 2.6 Copy RAC image into VM

```bash
scp -i oracle-rac/assets/vm-key oracle-rac/assets/rac-23.26.1.0.tar root@$VM_IP:/root/
```

## Step 3: Configure VM

All commands below run inside the VM via `$SSH`.

### 3.1 Install packages

```bash
dnf install -y podman git pip
pip install podman-compose
```

### 3.2 Run Oracle's host setup script

```bash
git clone https://github.com/oracle/docker-images.git /root/docker-images

export RAC_SECRET=oracle
bash /root/docker-images/OracleDatabase/RAC/OracleRealApplicationClusters/containerfiles/setup_rac_host.sh \
  -ignoreOSVersion -prepare-rac-env
```

Note: This will fail on the RAM check (requires 32GB, we have 16GB). That's OK for dev/test.

### 3.3 Fix hugepages for 16GB VM

Oracle's setup script sets `vm.nr_hugepages=16384` (32GB) in `/etc/sysctl.conf`.
On a 16GB VM, this consumes nearly all RAM, leaving the OS with only ~500MB and
causing OOM kills that prevent CRS from starting (cssdagent fails to initialize).

Reduce hugepages to 2048 (4GB) — enough for ASM + small DB SGAs:

```bash
sed -i 's/vm.nr_hugepages=16384/vm.nr_hugepages=2048/' /etc/sysctl.conf
sysctl -w vm.nr_hugepages=2048
```

### 3.4 Add swap (if needed to reach 32GB total)

```bash
dd if=/dev/zero of=/swapfile bs=1G count=28
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
```

### 3.5 Create ASM block devices

```bash
mkdir -p /oradata
truncate -s 50G /oradata/asm_disk01.img
truncate -s 50G /oradata/asm_disk02.img

losetup /dev/loop0 /oradata/asm_disk01.img
losetup /dev/loop1 /oradata/asm_disk02.img
ln -sf /dev/loop0 /dev/asm-disk1
ln -sf /dev/loop1 /dev/asm-disk2
```

Make persistent across reboots:

```bash
cat > /etc/systemd/system/asm-loop-devices.service << 'EOF'
[Unit]
Description=Setup ASM loop devices
After=local-fs.target
RequiresMountsFor=/oradata

[Service]
Type=oneshot
ExecStart=/bin/bash -c "losetup /dev/loop0 /oradata/asm_disk01.img && losetup /dev/loop1 /oradata/asm_disk02.img && ln -sf /dev/loop0 /dev/asm-disk1 && ln -sf /dev/loop1 /dev/asm-disk2"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable asm-loop-devices
```

### 3.6 Create Podman networks

```bash
podman network create --subnet 10.0.20.0/24 rac_pub1_nw
podman network create --subnet 192.168.17.0/24 rac_priv1_nw
podman network create --subnet 192.168.18.0/24 rac_priv2_nw
```

### 3.7 Load RAC image and build DNS server image

```bash
podman load -i /root/rac-23.26.1.0.tar
rm /root/rac-23.26.1.0.tar
```

```bash
cd /root/docker-images/OracleDatabase/RAC/OracleDNSServer/containerfiles/latest
podman build -t oracle/rac-dnsserver:latest .
```

### 3.8 Create the initsh fix script

Oracle's `/usr/bin/initsh` has a bug: it writes env vars to `/etc/rac_env_vars`
without quoting values. When `CRS_NODES` contains semicolons (multi-node separator),
the shell interprets `;` as a command separator, silently dropping the second node.

```bash
cat > /root/initsh-fixed << 'EOF'
#! /bin/bash

echo "Creating env variables file /etc/rac_env_vars"
# Read /proc/1/environ and write properly quoted export statements
python3 -c "
import sys
with open('/proc/1/environ', 'rb') as f:
    env_data = f.read()
for entry in env_data.split(b'\x00'):
    if entry and b'=' in entry:
        name, _, val = entry.partition(b'=')
        name = name.decode()
        val = val.decode()
        # Escape double quotes and backslashes in value
        val = val.replace(chr(92), chr(92)+chr(92)).replace(chr(34), chr(92)+chr(34))
        print(f'export {name}=\"{val}\"')
" > /etc/rac_env_vars

echo "Starting Systemd"
exec /lib/systemd/systemd
EOF
chmod +x /root/initsh-fixed
```

## Step 4: Create Shared Redo Log Directory

Create a shared directory on the VM host for redo logs. Both RAC containers and the
OLR container will bind-mount this directory, enabling OLR to read live online redo
logs directly (no ASM copy needed).

```bash
mkdir -p /shared/redo/onlinelog /shared/redo/archivelog
chown -R 54321:54335 /shared/redo
```

Oracle runs as uid 54321 / gid 54335 inside RAC containers. OLR should run with
`--user 1000:54335` so it can read Oracle's files via group permissions (640).

## Step 5: Deploy RAC Containers

Create the deployment script:

```bash
cat > /root/create-rac.sh << 'SCRIPT'
#!/bin/bash
set -e

CRS_NODES_VAL="pubhost:racnodep1,viphost:racnodep1-vip;pubhost:racnodep2,viphost:racnodep2-vip"

# --- DNS Server ---
podman create -t -i \
  --hostname racdns \
  --dns-search "example.info" \
  -e SETUP_DNS_CONFIG_FILES="setup_true" \
  -e DOMAIN_NAME=example.info \
  -e RAC_NODE_NAME_PREFIXP=racnodep \
  -e WEBMIN_ENABLED=false \
  --cap-add AUDIT_WRITE \
  --health-cmd "pgrep named" \
  --health-interval 60s --health-timeout 120s --health-retries 240 \
  --name rac-dnsserver \
  localhost/oracle/rac-dnsserver:latest

podman network disconnect podman rac-dnsserver
podman network connect rac_pub1_nw --ip 10.0.20.25 rac-dnsserver
podman start rac-dnsserver
echo "DNS server started"
sleep 5

# --- RAC Node 1 (install node) ---
podman create -t -i \
  --hostname racnodep1 \
  --dns-search "example.info" \
  --dns 10.0.20.25 \
  --shm-size 4G \
  --sysctl kernel.shmall=2097152 \
  --sysctl "kernel.sem=250 32000 100 128" \
  --sysctl kernel.shmmax=8589934592 \
  --sysctl kernel.shmmni=4096 \
  --sysctl "net.ipv4.conf.eth1.rp_filter=2" \
  --sysctl "net.ipv4.conf.eth2.rp_filter=2" \
  --cap-add=SYS_RESOURCE --cap-add=NET_ADMIN --cap-add=SYS_NICE \
  --cap-add=AUDIT_WRITE --cap-add=AUDIT_CONTROL --cap-add=NET_RAW \
  --secret pwdsecret --secret keysecret \
  --health-cmd "/bin/python3 /opt/scripts/startup/scripts/main.py --checkracstatus" \
  --health-interval 60s --health-timeout 120s --health-retries 240 \
  -v /root/initsh-fixed:/usr/bin/initsh:Z \
  -v /shared/redo:/shared/redo \
  -e DNS_SERVERS="10.0.20.25" \
  -e DB_SERVICE=service:orclpdb_app \
  -e CRS_PRIVATE_IP1=192.168.17.170 \
  -e CRS_PRIVATE_IP2=192.168.18.170 \
  -e CRS_NODES="$CRS_NODES_VAL" \
  -e SCAN_NAME=racnodepc1-scan \
  -e INIT_SGA_SIZE=3G -e INIT_PGA_SIZE=2G \
  -e INSTALL_NODE=racnodep1 \
  -e DB_PWD_FILE=pwdsecret -e PWD_KEY=keysecret \
  --device=/dev/asm-disk1:/dev/asm-disk1 \
  --device=/dev/asm-disk2:/dev/asm-disk2 \
  -e CRS_ASM_DEVICE_LIST=/dev/asm-disk1,/dev/asm-disk2 \
  -e OP_TYPE=setuprac \
  --restart=always --ulimit rtprio=99 --systemd=always \
  --name racnodep1 \
  container-registry.oracle.com/database/rac:23.26.1.0

podman network disconnect podman racnodep1
podman network connect rac_pub1_nw --ip 10.0.20.170 racnodep1
podman network connect rac_priv1_nw --ip 192.168.17.170 racnodep1
podman network connect rac_priv2_nw --ip 192.168.18.170 racnodep1

# --- RAC Node 2 ---
podman create -t -i \
  --hostname racnodep2 \
  --dns-search "example.info" \
  --dns 10.0.20.25 \
  --shm-size 4G \
  --sysctl kernel.shmall=2097152 \
  --sysctl "kernel.sem=250 32000 100 128" \
  --sysctl kernel.shmmax=8589934592 \
  --sysctl kernel.shmmni=4096 \
  --sysctl "net.ipv4.conf.eth1.rp_filter=2" \
  --sysctl "net.ipv4.conf.eth2.rp_filter=2" \
  --cap-add=SYS_RESOURCE --cap-add=NET_ADMIN --cap-add=SYS_NICE \
  --cap-add=AUDIT_WRITE --cap-add=AUDIT_CONTROL --cap-add=NET_RAW \
  --secret pwdsecret --secret keysecret \
  --health-cmd "/bin/python3 /opt/scripts/startup/scripts/main.py --checkracstatus" \
  --health-interval 60s --health-timeout 120s --health-retries 240 \
  -v /root/initsh-fixed:/usr/bin/initsh:Z \
  -v /shared/redo:/shared/redo \
  -e DNS_SERVERS="10.0.20.25" \
  -e DB_SERVICE=service:orclpdb_app \
  -e CRS_PRIVATE_IP1=192.168.17.171 \
  -e CRS_PRIVATE_IP2=192.168.18.171 \
  -e CRS_NODES="$CRS_NODES_VAL" \
  -e SCAN_NAME=racnodepc1-scan \
  -e INIT_SGA_SIZE=3G -e INIT_PGA_SIZE=2G \
  -e INSTALL_NODE=racnodep1 \
  -e DB_PWD_FILE=pwdsecret -e PWD_KEY=keysecret \
  --device=/dev/asm-disk1:/dev/asm-disk1 \
  --device=/dev/asm-disk2:/dev/asm-disk2 \
  -e CRS_ASM_DEVICE_LIST=/dev/asm-disk1,/dev/asm-disk2 \
  -e OP_TYPE=setuprac \
  --restart=always --ulimit rtprio=99 --systemd=always \
  --name racnodep2 \
  container-registry.oracle.com/database/rac:23.26.1.0

podman network disconnect podman racnodep2
podman network connect rac_pub1_nw --ip 10.0.20.171 racnodep2
podman network connect rac_priv1_nw --ip 192.168.17.171 racnodep2
podman network connect rac_priv2_nw --ip 192.168.18.171 racnodep2

# --- Start ---
podman start racnodep1
podman start racnodep2
echo "RAC nodes started — provisioning takes ~15 minutes"
SCRIPT
chmod +x /root/create-rac.sh
```

Run it:

```bash
bash /root/create-rac.sh
```

### Monitor provisioning

```bash
podman exec racnodep1 bash -c "tail -f /tmp/orod/oracle_db_setup.log"
```

When complete, you'll see:

```
ORACLE RAC DATABASE IS READY TO USE
```

### Verify

```bash
podman ps -a   # all 3 containers should show (healthy)
podman exec racnodep1 su - oracle -c "srvctl status database -d ORCLCDB"
# Expected: Instance ORCLCDB1 is running on node racnodep1
#           Instance ORCLCDB2 is running on node racnodep2
```

## Step 6: Migrate Redo Logs to Shared Filesystem

After RAC provisioning completes, migrate online redo logs from ASM to the shared
directory and redirect archive log destination there.

### 6.1 Add new redo log groups on shared FS

Connect as sysdba on node 1 and add 2 groups per thread:

```sql
-- From inside racnodep1 as sysdba on ORCLCDB1
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 5 ('/shared/redo/onlinelog/redo_t1_g5.log') SIZE 1G;
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 6 ('/shared/redo/onlinelog/redo_t1_g6.log') SIZE 1G;
ALTER DATABASE ADD LOGFILE THREAD 2 GROUP 7 ('/shared/redo/onlinelog/redo_t2_g7.log') SIZE 1G;
ALTER DATABASE ADD LOGFILE THREAD 2 GROUP 8 ('/shared/redo/onlinelog/redo_t2_g8.log') SIZE 1G;
```

### 6.2 Switch logs and drop old ASM groups

Force log switches on both nodes to drain the old groups:

```sql
-- On node 1
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM CHECKPOINT;
```

```sql
-- On node 2
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM CHECKPOINT;
```

Wait for old groups (1-4) to become INACTIVE:

```sql
SELECT THREAD#, GROUP#, STATUS FROM V$LOG ORDER BY THREAD#, GROUP#;
```

Drop the old ASM-based groups:

```sql
ALTER DATABASE DROP LOGFILE GROUP 1;
ALTER DATABASE DROP LOGFILE GROUP 2;
ALTER DATABASE DROP LOGFILE GROUP 3;
ALTER DATABASE DROP LOGFILE GROUP 4;
```

### 6.3 Redirect archive log destination

```sql
ALTER SYSTEM SET log_archive_dest_1='LOCATION=/shared/redo/archivelog' SCOPE=BOTH SID='*';
```

Verify with a log switch:

```sql
ALTER SYSTEM SWITCH LOGFILE;
-- Check archive appeared on shared FS:
-- ls -la /shared/redo/archivelog/
```

## Step 7: Run OpenLogReplicator

### 7.1 Create OLR user and grants

Connect as sysdba and create a common user for OLR:

```sql
CREATE USER C##USROLR IDENTIFIED BY oracle CONTAINER=ALL;
GRANT CREATE SESSION TO C##USROLR CONTAINER=ALL;
GRANT SELECT_CATALOG_ROLE TO C##USROLR CONTAINER=ALL;
GRANT LOGMINING TO C##USROLR CONTAINER=ALL;
```

Apply the grants from `scripts/grants.sql` **in PDB context** (CDB-level grants
do not propagate FLASHBACK privileges on SYS tables to the PDB):

```sql
ALTER SESSION SET CONTAINER=ORCLPDB;
-- Run each GRANT from scripts/grants.sql with <USER> replaced by C##USROLR
```

### 7.2 Load OLR image

Transfer the OLR image to the VM and load it:

```bash
# On host:
docker save bersler/openlogreplicator:debian-13.0 | \
  ssh -i oracle-rac/assets/vm-key root@$VM_IP 'podman load'
```

### 7.3 Create OLR directories and config

```bash
mkdir -p /root/olr/scripts /root/olr/checkpoint /root/olr/output
```

Create `/root/olr/scripts/OpenLogReplicator.json` — adjust `start-scn` to the
current SCN (`SELECT CURRENT_SCN FROM V$DATABASE`):

```json
{
  "version": "1.8.7",
  "source": [{
    "alias": "RAC1",
    "name": "ORCLCDB",
    "reader": {
      "type": "online",
      "start-scn": 0,
      "path-mapping": ["/shared/redo", "/shared/redo"],
      "server": "//10.0.20.170:1521/ORCLPDB",
      "user": "c##usrolr",
      "password": "oracle"
    },
    "format": {
      "type": "json",
      "column": 1
    },
    "memory": {
      "min-mb": 64,
      "max-mb": 1024
    },
    "filter": {
      "table": [
        {"owner": "USRTBL", "table": "TEST1"}
      ]
    }
  }],
  "target": [{
    "alias": "FILE1",
    "source": "RAC1",
    "writer": {
      "type": "file",
      "output": "/opt/output/results.txt",
      "new-line": 1,
      "max-file-size": 1073741824,
      "append": 1
    }
  }]
}
```

### 7.4 Start OLR container

Oracle creates redo and archive files as uid 54321 / gid 54335 with 640 permissions.
OLR runs as uid 1000 by default and cannot read these files. Use `--user 1000:54335`
to run OLR with Oracle's group, granting read access without changing file permissions:

```bash
podman run -d --name olr \
  --user 1000:54335 \
  -v /root/olr/scripts:/opt/OpenLogReplicator/scripts:ro \
  -v /root/olr/checkpoint:/opt/OpenLogReplicator/checkpoint \
  -v /root/olr/output:/opt/output \
  -v /shared/redo:/shared/redo:ro \
  bersler/openlogreplicator:debian-13.0
```

Verify it started correctly:

```bash
podman logs olr 2>&1 | grep -E 'processing|ERROR'
```

## Step 8: Shutdown and Restart

Reference: [Oracle RAC on Podman — Target Configuration](https://docs.oracle.com/en/database/oracle/oracle-database/26/racpd/target-configuration-oracle-rac-podman.html)

### Graceful shutdown (inside VM)

Stop CRS on each node before stopping containers. Node 2 first, then node 1.
Note: `crsctl stop crs` must run as root (not grid):

```bash
podman exec racnodep2 /u01/app/23ai/grid/bin/crsctl stop crs
podman exec racnodep1 /u01/app/23ai/grid/bin/crsctl stop crs
podman stop racnodep2 racnodep1 rac-dnsserver
```

If CRS stop hangs, use `-f` to force:

```bash
podman exec racnodep2 /u01/app/23ai/grid/bin/crsctl stop crs -f
podman exec racnodep1 /u01/app/23ai/grid/bin/crsctl stop crs -f
podman stop racnodep2 racnodep1 rac-dnsserver
```

### Shutdown the VM (from host)

After containers are stopped:

```bash
virsh -c qemu:///system shutdown oracle-rac-vm
```

### Start the VM (from host)

```bash
virsh -c qemu:///system start oracle-rac-vm
# Wait for SSH to become available
```

### Restart containers (inside VM)

Containers do not auto-start on VM boot (see Known Issues #4). You must start them manually.

The ASM loop devices should be recreated automatically by the `asm-loop-devices` systemd
service. Verify before starting containers:

```bash
# Verify loop devices exist
ls -la /dev/asm-disk1 /dev/asm-disk2
# If missing, recreate manually:
# losetup /dev/loop0 /oradata/asm_disk01.img
# losetup /dev/loop1 /oradata/asm_disk02.img
# ln -sf /dev/loop0 /dev/asm-disk1
# ln -sf /dev/loop1 /dev/asm-disk2
```

Start containers in order — DNS first, then RAC nodes:

```bash
podman start rac-dnsserver
sleep 5
podman start racnodep1
podman start racnodep2
```

Wait for CRS to come online (~2-5 minutes):

```bash
# Check CRS stack status
podman exec racnodep1 su - grid -c "crsctl check crs"
# Expected output when ready:
#   CRS-4638: Oracle High Availability Services is online
#   CRS-4537: Cluster Ready Services is online
#   CRS-4529: Cluster Synchronization Services is online
#   CRS-4533: Event Manager is online
```

Verify the database:

```bash
podman exec racnodep1 su - oracle -c "srvctl status database -d ORCLCDB"
```

## Step 9: Teardown / Recreate

### Remove and recreate containers (keeps ASM data)

```bash
podman stop racnodep2 racnodep1 rac-dnsserver
podman rm racnodep2 racnodep1 rac-dnsserver
bash /root/create-rac.sh
```

The `initsh` script detects the existing ASM diskgroup and reuses it.
Provisioning takes ~15 minutes.

### Full reset (wipe ASM and rebuild)

```bash
podman stop racnodep2 racnodep1 rac-dnsserver
podman rm racnodep2 racnodep1 rac-dnsserver
dd if=/dev/zero of=/dev/asm-disk1 bs=8k count=10000
dd if=/dev/zero of=/dev/asm-disk2 bs=8k count=10000
bash /root/create-rac.sh
```

After rebuild completes, repeat Step 6 to migrate redo logs to shared FS.

### Recreate VM from scratch

On the host, destroy the old VM and repeat from Step 2.4:

```bash
virsh -c qemu:///system destroy oracle-rac-vm
virsh -c qemu:///system undefine oracle-rac-vm
rm oracle-rac/assets/OL9-vm.qcow2
# Then repeat from Step 2.4 onwards
```

## Key Details

| Item | Value |
|------|-------|
| CDB | ORCLCDB |
| PDB | ORCLPDB |
| SYS/SYSTEM password | oracle |
| SGA | 3GB per instance |
| PGA | 2GB per instance |
| ASM diskgroup | +DATA (102GB, EXTERNAL redundancy) |
| Online redo logs | `/shared/redo/onlinelog/` (groups 5-8) |
| Archive log dest | `/shared/redo/archivelog/` |
| App service | orclpdb_app (connects to ORCLPDB) |
| SCAN name | racnodepc1-scan |
| Domain | example.info |

## Files

All dynamic assets live in `oracle-rac/assets/` (gitignored):

| File | Description | Reusable? |
|------|-------------|-----------|
| `assets/OL9U7_x86_64-kvm-b269.qcow2` | Original OL9 cloud image (~800MB) | Yes — base image, never modified |
| `assets/OL9-vm.qcow2` | VM runtime disk (grows to ~60GB+) | No — destroyed on VM recreate |
| `assets/rac-23.26.1.0.tar` | RAC container image (~14GB) | Yes — loaded into each new VM |
| `assets/vm-key` / `vm-key.pub` | SSH keypair | Yes |
| `assets/cloud-init.yaml` | Cloud-init user-data | Yes |
| `assets/cloud-init.iso` | Cloud-init ISO | Yes — regenerate if yaml changes |

## Known Issues

1. **`--systemd=always` required**: Without this Podman flag, `exec /lib/systemd/systemd`
   exits immediately with code 255. Compose files don't support this flag — must use
   `podman create` directly.

2. **`initsh` env var quoting bug**: Oracle's init script writes unquoted env vars.
   `CRS_NODES` contains semicolons which get interpreted as shell command separators,
   silently dropping the second node. Fixed with bind-mounted `initsh-fixed`.

3. **16GB RAM**: Oracle requires 32GB but 16GB works for dev/test. The `setup_rac_host.sh`
   will report an error but the cluster runs fine.

4. **Containers don't auto-start on VM boot**: Podman is daemonless, so `--restart=always`
   only applies while Podman is running. The `podman-restart.service` exists but is disabled
   by default. We keep it disabled intentionally — DNS must start before RAC nodes, and
   `podman-restart` doesn't guarantee ordering. Start containers manually after VM boot
   (see Step 5). If the VM reboots unexpectedly, CRS handles crash recovery automatically
   once containers are started (~3 minutes).
