#!/bin/bash
#
# Common setup for all servers (Control Plane and Nodes)

set -euxo pipefail

# Kubernetes Variable Declaration
KUBERNETES_VERSION="v1.34"
CRICTL_VERSION="v1.35.0"
KUBERNETES_INSTALL_VERSION="1.34.4-1.1"

# Disable swap
sudo swapoff -a

# Keeps the swap off during reboot
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true
sudo apt-get update -y

# Create the .conf file to load the modules at bootup
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# Optimized for 32-core nodes and high-throughput Spark shuffles
# Increase max open files (essential for billions of shuffle blocks)
fs.file-max = 1000000
# Essential for Sedona's mmap-based spatial indexing
vm.max_map_count = 262144
# Improve network throughput for large data transfers (Spark shuffle)
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# Enable BBR congestion control (faster data movement across nodes)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Verify Cgroup v2 is enabled (K8s 1.34 standard)
if [ ! -d "/sys/fs/cgroup/cgroup.procs" ]; then
    echo "Warning: Cgroup v2 not detected. K8s 1.34 performance may be degraded."
fi

if ! command -v kubeadm &> /dev/null; then
    
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg
    
    # Install containerd Runtime
    sudo apt-get update -y
    sudo apt-get install -y software-properties-common curl apt-transport-https ca-certificates
    
    
    
    sudo apt-get update
    sudo apt-get install ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install containerd.io
    
    sudo systemctl daemon-reload
    sudo systemctl enable containerd --now
    sudo systemctl start containerd.service
    
    echo "Containerd runtime installed successfully"
    
    # Generate the default containerd configuration
    sudo containerd config default | sudo tee /etc/containerd/config.toml
    
    # Enable SystemdCgroup clear
    
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Restart containerd to apply changes
    sudo systemctl restart containerd
    
    # Detect architecture for downloads (amd64 vs arm64)
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
      amd64) CRICTL_ARCH="amd64" ;;
      arm64) CRICTL_ARCH="arm64" ;;
      *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac
    
    CRICTL_VERSION="v1.35.0"
    # Install crictl
    # Install crictl (amd64/arm64 based on system)
    curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"
    sudo tar zxvf "crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" -C /usr/local/bin
    rm -f "crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"
    
    # Configure crictl to use containerd
    cat <<EOF | sudo tee /etc/crictl.yaml
    runtime-endpoint: unix:///run/containerd/containerd.sock
    image-endpoint: unix:///run/containerd/containerd.sock
    timeout: 10
    debug: false
EOF
    
    echo "crictl installed and configured successfully"
    
    # Install kubelet, kubectl, and kubeadm
    curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key |
        gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" |
        tee /etc/apt/sources.list.d/kubernetes.list
    
    sudo apt-get update -y
    sudo apt-get install -y kubelet="$KUBERNETES_INSTALL_VERSION" kubectl="$KUBERNETES_INSTALL_VERSION" kubeadm="$KUBERNETES_INSTALL_VERSION"
    
    # Prevent automatic updates for kubelet, kubeadm, and kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    
    sudo apt-get update -y
    
    # Install jq, a command-line JSON processor, and unzip
    sudo apt-get install -y jq unzip
else
    echo "Kubeadm detected. Golden AMI boot in progress. Skipping apt installations!"
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

if ! command -v nvme &> /dev/null; then
    sudo apt-get install -y nvme-cli
fi

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
    
    sudo apt-get install -y mdadm
    
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