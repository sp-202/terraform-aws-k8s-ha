#!/bin/bash
# Setup for Control Plane (Master) servers - Runtime optimized - V2 (Forced Refresh)

set -euxo pipefail

PUBLIC_IP_ACCESS="false"
NODENAME=$(hostname -s)
POD_CIDR="10.0.0.0/8"

# Ensure etcd data dir exists with correct permissions
sudo mkdir -p /var/lib/etcd
sudo chmod 0700 /var/lib/etcd

sudo kubeadm config images pull

if [ ! -d "/sys/fs/cgroup/cgroup.procs" ]; then
    echo "Warning: Cgroup v2 not detected. K8s 1.34 performance may be degraded."
fi

if [[ "$PUBLIC_IP_ACCESS" == "false" ]]; then
    MASTER_PRIVATE_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
    ADVERTISE_ADDRESS="$MASTER_PRIVATE_IP"
    CERT_SANS="$MASTER_PRIVATE_IP,127.0.0.1,localhost"
elif [[ "$PUBLIC_IP_ACCESS" == "true" ]]; then
    MASTER_PRIVATE_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
    MASTER_PUBLIC_IP=$(curl ifconfig.me && echo "")
    ADVERTISE_ADDRESS="0.0.0.0"
    CERT_SANS="$MASTER_PUBLIC_IP,$MASTER_PRIVATE_IP,127.0.0.1,localhost"
else
    echo "Error: PUBLIC_IP_ACCESS has an invalid value: $PUBLIC_IP_ACCESS"
    exit 1
fi

# Generate kubeadm config with etcd tuning for cloud environments
cat > /tmp/kubeadm-config.yaml << KUBEADM_EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: "$POD_CIDR"
apiServer:
  certSANs:
$(for san in $(echo $CERT_SANS | tr ',' ' '); do echo "    - $san"; done)
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: heartbeat-interval
        value: "500"
      - name: election-timeout
        value: "5000"
      - name: quota-backend-bytes
        value: "2147483648"
      - name: auto-compaction-retention
        value: "1"
      - name: snapshot-count
        value: "5000"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$ADVERTISE_ADDRESS"
nodeRegistration:
  name: "$NODENAME"
  ignorePreflightErrors:
    - Swap
    - DirAvailable--var-lib-etcd
bootstrapTokens:
  - token: "__BOOTSTRAP_TOKEN__"
KUBEADM_EOF

sudo kubeadm init --config /tmp/kubeadm-config.yaml

USER_HOME="/home/ubuntu"
USER_ID=$(id -u ubuntu)
GROUP_ID=$(id -g ubuntu)

mkdir -p "$USER_HOME"/.kube
sudo cp /etc/kubernetes/admin.conf "$USER_HOME"/.kube/config
sudo chown "$USER_ID":"$GROUP_ID" "$USER_HOME"/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# # Remove kube-proxy if it got installed anyway
# kubectl -n kube-system delete daemonset kube-proxy 2>/dev/null || true
# kubectl -n kube-system delete configmap kube-proxy 2>/dev/null || true

# Fix environment for Cilium CLI under cloud-init
export HOME=/root

# Install Cilium
cilium install \
  --version 1.16.5 \
  --set ipam.mode=eni \
  --set eni.enabled=true \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR="10.0.0.0/8" \
  --set kubeProxyReplacement=false \
  --set nodePort.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set eni.awsEnableInstanceTypeDetails=true \
  --set eni.updateEC2AdapterLimitViaAPI=true \
  --set 'eni.subnetTags.cilium-pod-subnet=1' \
  --set bpf.preallocateMaps=false

echo "Waiting for Cilium to initialize..."
sleep 30

if cilium status --wait --wait-duration=120s; then
  echo "Cilium healthy — removing kube-proxy"
  kubectl -n kube-system delete daemonset kube-proxy 2>/dev/null || true
  kubectl -n kube-system delete configmap kube-proxy 2>/dev/null || true
else
  echo "WARNING: Cilium not fully healthy after 120s — continuing anyway"
  echo "Cilium will reach health eventually; kube-proxy cleanup deferred"
  cilium status || true  # dump status to log for debugging (|| true prevents set -e abort)
  # DO NOT exit here — let the rest of the setup (NTH, OpenEBS, auto-labeler) proceed
fi

# Install AWS Node Termination Handler
echo "Installing AWS Node Termination Handler..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-node-termination-handler \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set enableRebalanceMonitoring=true \
  eks/aws-node-termination-handler

# Wait for I/O to settle before next install
echo "Waiting for I/O to settle before OpenEBS install..."
sleep 30

# ------ OpenEBS Install ------
echo "Installing OpenEBS..."
helm repo add openebs https://openebs.github.io/charts
helm repo update
helm upgrade --install openebs openebs/openebs \
  --namespace openebs --create-namespace \
  --set localprovisioner.enabled=true

# Start Node Auto-Labeling Daemon for ROLES
cat << 'EOD' > /usr/local/bin/auto-label-nodes.sh
#!/bin/bash
export KUBECONFIG=/etc/kubernetes/admin.conf
while true; do
  for node in $(kubectl get nodes --no-headers | awk '{print $1}'); do
    if [[ $node == spark-worker-* ]]; then kubectl label node $node node-role.kubernetes.io/spark-worker='' --overwrite; fi
    if [[ $node == minio-worker-* ]]; then kubectl label node $node node-role.kubernetes.io/minio-worker='' --overwrite; fi
    if [[ $node == spark-node-* ]]; then kubectl label node $node node-role.kubernetes.io/spark-node='' --overwrite; fi
    if [[ $node == k8s-gp-node-* ]]; then kubectl label node $node node-role.kubernetes.io/k8s-gp-node='' --overwrite; fi
  done
  sleep 10
done
EOD

chmod +x /usr/local/bin/auto-label-nodes.sh

cat << 'EOD' > /etc/systemd/system/k8s-auto-label.service
[Unit]
Description=Kubernetes Auto Node Labeler
After=kubelet.service

[Service]
ExecStart=/usr/local/bin/auto-label-nodes.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOD

systemctl daemon-reload
systemctl enable --now k8s-auto-label.service
