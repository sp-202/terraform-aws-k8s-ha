#!/bin/bash
echo "Looking for available local NVMe instance store disks..."
DISK_DEV=""

# Ensure nvme-cli is installed
if ! command -v nvme &> /dev/null; then
    sudo apt-get install -y nvme-cli
fi

for dev in $(ls /dev/nvme*n1 2>/dev/null); do
    # Check if the model explicitly says "Amazon EC2 NVMe Instance Storage"
    MODEL=$(sudo nvme id-ctrl "$dev" | grep -i mn | awk -F':' '{print $2}' | xargs || true)
    
    if [[ "$MODEL" == *"Instance Storage"* ]]; then
        # Double check it isn't mounted just in case
        mount_count=$(mount | grep -c "$dev" || true)
        if [ "$mount_count" -eq 0 ]; then
             DISK_DEV="$dev"
             break
        fi
    fi
done
