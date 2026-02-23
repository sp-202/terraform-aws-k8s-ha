#!/bin/bash
#
# Common runtime setup for all servers (Control Plane and Nodes) - Golden AMI optimized

set -euxo pipefail

# Disable swap
sudo swapoff -a

# Keeps the swap off during reboot
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true

# Apply sysctl params without reboot (Settings baked into /etc/sysctl.d/k8s.conf via AMI)
sudo sysctl --system

# Verify Cgroup v2 is enabled (K8s 1.34 standard)
if [ ! -d "/sys/fs/cgroup/cgroup.procs" ]; then
    echo "Warning: Cgroup v2 not detected. K8s 1.34 performance may be degraded."
fi

# Retrieve the default interface IP address and set it for kubelet
local_ip="$(ip -j route get 8.8.8.8 | jq -r '.[0].prefsrc')"

# Write the local IP address to the kubelet default configuration file
cat > /etc/default/kubelet << EOF
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF

# 2. NVMe Mount Optimization (The "IOPS" Boost)
# Discovers ALL local instance store NVMe drives and:
#   - 1 drive  → format as XFS directly
#   - 2+ drives → RAID0 stripe with mdadm for maximum IOPS/throughput
echo "Looking for available local NVMe instance store disks..."

# Collect all unmounted instance store NVMe drives
NVME_DRIVES=()
for dev in $(ls /dev/nvme*n1 2>/dev/null); do
    MODEL=$(sudo nvme id-ctrl "$dev" 2>/dev/null | grep -i mn | awk -F':' '{print $2}' | xargs || true)
    
    if [[ "$MODEL" == *"Instance Storage"* ]]; then
        mount_count=$(mount | grep -c "$dev" || true)
        if [ "$mount_count" -eq 0 ]; then
            NVME_DRIVES+=("$dev")
        fi
    fi
done

DRIVE_COUNT=${#NVME_DRIVES[@]}
echo "Found $DRIVE_COUNT unmounted instance store NVMe drive(s)."

if [ "$DRIVE_COUNT" -eq 0 ]; then
    echo "No instance store NVMe drives found. Skipping NVMe setup."

elif [ "$DRIVE_COUNT" -eq 1 ]; then
    # Single drive — format directly as XFS
    DISK_DEV="${NVME_DRIVES[0]}"
    echo "Single NVMe drive detected: $DISK_DEV. Formatting as XFS..."
    
    FSTYPE=$(lsblk -no FSTYPE "$DISK_DEV" 2>/dev/null || true)
    if [ "$FSTYPE" != "xfs" ]; then
        sudo mkfs.xfs -f -K "$DISK_DEV"
    fi
    
    sudo mkdir -p /mnt/spark-nvme
    mount_check=$(grep -c "/mnt/spark-nvme" /proc/mounts || true)
    if [ "$mount_check" -eq 0 ]; then
        sudo mount -o noatime,nodiratime,logbsize=256k "$DISK_DEV" /mnt/spark-nvme
    fi
    
    fstab_check=$(grep -c "/mnt/spark-nvme" /etc/fstab || true)
    if [ "$fstab_check" -eq 0 ]; then
        echo "$DISK_DEV /mnt/spark-nvme xfs defaults,noatime,nodiratime 0 0" >> /etc/fstab
    fi
    echo "Single NVMe $DISK_DEV mounted at /mnt/spark-nvme"

else
    # Multiple drives — RAID0 stripe for maximum IOPS & throughput
    echo "Multiple NVMe drives detected: ${NVME_DRIVES[*]}. Creating RAID0 array..."
    
    # mdadm is already installed in the AMI
    
    # Check if /dev/md0 already exists
    if [ -e /dev/md0 ]; then
        echo "RAID array /dev/md0 already exists. Skipping creation."
    else
        sudo mdadm --create /dev/md0 \
            --level=0 \
            --raid-devices="$DRIVE_COUNT" \
            "${NVME_DRIVES[@]}" \
            --force --run
        
        # Wait for array to initialize
        sudo mdadm --wait /dev/md0 2>/dev/null || true
        
        # Save RAID config so it persists across reboots
        sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
        sudo update-initramfs -u
    fi
    
    # Format as XFS if not already
    FSTYPE=$(lsblk -no FSTYPE /dev/md0 2>/dev/null || true)
    if [ "$FSTYPE" != "xfs" ]; then
        sudo mkfs.xfs -f -K /dev/md0
    fi
    
    sudo mkdir -p /mnt/spark-nvme
    mount_check=$(grep -c "/mnt/spark-nvme" /proc/mounts || true)
    if [ "$mount_check" -eq 0 ]; then
        sudo mount -o noatime,nodiratime,logbsize=256k /dev/md0 /mnt/spark-nvme
    fi
    
    fstab_check=$(grep -c "/mnt/spark-nvme" /etc/fstab || true)
    if [ "$fstab_check" -eq 0 ]; then
        echo "/dev/md0 /mnt/spark-nvme xfs defaults,noatime,nodiratime 0 0" >> /etc/fstab
    fi
    echo "RAID0 array of $DRIVE_COUNT NVMe drives mounted at /mnt/spark-nvme"
fi
