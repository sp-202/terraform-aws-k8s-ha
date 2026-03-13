#!/bin/bash
# Common setup for Golden AMI — Generic ARM64, instance-type agnostic
set -euxo pipefail

# ============================================================
# PINNED VERSIONS — update these intentionally, never auto-pull
# ============================================================
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.34}"
KUBERNETES_INSTALL_VERSION="1.34.4-1.1"
CRICTL_VERSION="v1.34.0"          # match k8s version
CILIUM_CLI_VERSION="v0.18.3"      # pinned — compatible with Cilium 1.16.5
HELM_VERSION="v3.16.4"            # pinned stable
KERNEL_VERSION="6.8.0-1021-aws"   # pinned — validated with Cilium 1.16.5 on ARM64

# ============================================================
# 1. Pin Kernel Version — prevents auto-upgrade to untested kernels
# ============================================================
echo "Pinning kernel to $KERNEL_VERSION..."
sudo apt-get update -y

# Install pinned kernel if not already running it
CURRENT_KERNEL=$(uname -r)
if [[ "$CURRENT_KERNEL" != "$KERNEL_VERSION" ]]; then
    sudo apt-get install -y \
        linux-image-${KERNEL_VERSION} \
        linux-headers-${KERNEL_VERSION} \
        linux-modules-extra-${KERNEL_VERSION} || true
fi

# Hold kernel packages — prevents unattended-upgrades from pulling new kernels
sudo apt-mark hold \
    linux-aws \
    linux-image-aws \
    linux-headers-aws \
    linux-modules-extra-aws || true

# Remove unattended-upgrades to prevent kernel drift in prod
sudo apt-get remove -y unattended-upgrades || true
sudo apt-get autoremove -y || true

# ============================================================
# 2. Base Packages
# ============================================================
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gpg \
    software-properties-common \
    jq \
    unzip \
    nvme-cli \
    mdadm \
    ebsnvme-id \
    iproute2 \
    net-tools \
    ethtool \
    socat \
    conntrack \
    ipset \
    iptables \
    nfs-common \
    xfsprogs \
    e2fsprogs

# ============================================================
# 3. Disable Swap permanently
# ============================================================
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# ============================================================
# 4. Kernel Modules — load now and persist across reboots
# ============================================================
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# ============================================================
# 5. Sysctl — Kubernetes + performance tuning
# ============================================================
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
# K8s networking requirements
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# File descriptor limits
fs.file-max = 1000000
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Memory
vm.max_map_count = 262144
vm.swappiness = 0

# Network performance
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_max_syn_backlog = 8096

# Cilium ENI requirements
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
EOF

sudo sysctl --system

# ============================================================
# 6. Containerd Runtime
# ============================================================
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update

CONTAINERD_VERSION=$(apt-cache madison containerd.io | \
    awk '{print $3}' | grep -E '^2\.[0-9]+\.[0-9]+' | head -n1)
if [ -z "$CONTAINERD_VERSION" ]; then
    echo "Error: Failed to find Containerd 2.x in apt cache."
    exit 1
fi
echo "Installing containerd $CONTAINERD_VERSION..."
sudo apt-get install -y containerd.io="$CONTAINERD_VERSION"
sudo apt-mark hold containerd.io

# Containerd config — enable SystemdCgroup and set sandbox image
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Set correct pause image for k8s 1.34
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|g' \
    /etc/containerd/config.toml

sudo systemctl enable containerd --now
sudo systemctl is-active containerd

# ============================================================
# 7. Kubernetes Binaries
# ============================================================
curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y \
    kubelet="$KUBERNETES_INSTALL_VERSION" \
    kubectl="$KUBERNETES_INSTALL_VERSION" \
    kubeadm="$KUBERNETES_INSTALL_VERSION"
sudo apt-mark hold kubelet kubeadm kubectl

# Placeholder kubelet config — overwritten at boot by common-runtime.sh
# Prevents kubelet starting with wrong node-ip before runtime script runs
cat > /etc/default/kubelet << 'EOF'
# Populated at boot by common-runtime.sh
KUBELET_EXTRA_ARGS=--node-ip=127.0.0.1
EOF

sudo systemctl enable kubelet

# ============================================================
# 8. Crictl — pinned to match k8s version
# ============================================================
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) CRICTL_ARCH="amd64" ;;
  arm64) CRICTL_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo "Installing crictl $CRICTL_VERSION..."
curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
    -o crictl.tar.gz
sudo tar zxvf crictl.tar.gz -C /usr/local/bin
rm -f crictl.tar.gz

cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# ============================================================
# 9. Cilium CLI — pinned version
# ============================================================
echo "Installing Cilium CLI $CILIUM_CLI_VERSION..."
CLI_ARCH="amd64"
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH="arm64"; fi

curl -fsSL \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" \
    -o cilium-cli.tar.gz
curl -fsSL \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz.sha256sum" \
    -o cilium-cli.tar.gz.sha256sum

sha256sum --check cilium-cli.tar.gz.sha256sum
sudo tar xzvfC cilium-cli.tar.gz /usr/local/bin
rm -f cilium-cli.tar.gz cilium-cli.tar.gz.sha256sum

cilium version --client

# ============================================================
# 10. Helm 3 — pinned version
# ============================================================
echo "Installing Helm $HELM_VERSION..."
CLI_ARCH="amd64"
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH="arm64"; fi

curl -fsSL \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${CLI_ARCH}.tar.gz" \
    -o helm.tar.gz
tar xzvf helm.tar.gz
sudo mv linux-${CLI_ARCH}/helm /usr/local/bin/helm
rm -rf helm.tar.gz linux-${CLI_ARCH}/

helm version

# ============================================================
# 11. Verify all tools installed correctly
# ============================================================
echo "=== Verifying installations ==="
kubelet --version
kubeadm version
kubectl version --client
containerd --version
crictl --version
cilium version --client
helm version
nvme version
ebsnvme-id --version || true
aws --version 2>/dev/null || echo "AWS CLI not yet installed (installed separately)"

echo "=== common-ami.sh complete ==="