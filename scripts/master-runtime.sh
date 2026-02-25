#!/bin/bash
# Setup for Control Plane (Master) servers - Runtime optimized - V2 (Forced Refresh)

set -euxo pipefail

PUBLIC_IP_ACCESS="false"
NODENAME=$(hostname -s)
POD_CIDR="10.244.0.0/16"

sudo kubeadm config images pull

if [ ! -d "/sys/fs/cgroup/cgroup.procs" ]; then
    echo "Warning: Cgroup v2 not detected. K8s 1.34 performance may be degraded."
fi

if [[ "$PUBLIC_IP_ACCESS" == "false" ]]; then
    MASTER_PRIVATE_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
    sudo kubeadm init --apiserver-advertise-address="$MASTER_PRIVATE_IP" --apiserver-cert-extra-sans="$MASTER_PRIVATE_IP,127.0.0.1,localhost" --pod-network-cidr="$POD_CIDR" --node-name "$NODENAME" --ignore-preflight-errors Swap
elif [[ "$PUBLIC_IP_ACCESS" == "true" ]]; then
    MASTER_PRIVATE_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
    MASTER_PUBLIC_IP=$(curl ifconfig.me && echo "")
    sudo kubeadm init \
        --apiserver-advertise-address="0.0.0.0" \
        --apiserver-cert-extra-sans="$MASTER_PUBLIC_IP,$MASTER_PRIVATE_IP,127.0.0.1,localhost" \
        --pod-network-cidr="$POD_CIDR" \
        --node-name "$NODENAME" \
        --ignore-preflight-errors Swap
else
    echo "Error: MASTER_PUBLIC_IP has an invalid value: $PUBLIC_IP_ACCESS"
    exit 1
fi

USER_HOME="/home/ubuntu"
USER_ID=$(id -u ubuntu)
GROUP_ID=$(id -g ubuntu)

mkdir -p "$USER_HOME"/.kube
sudo cp /etc/kubernetes/admin.conf "$USER_HOME"/.kube/config
sudo chown "$USER_ID":"$GROUP_ID" "$USER_HOME"/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# Remove kube-proxy if it got installed anyway
kubectl -n kube-system delete daemonset kube-proxy 2>/dev/null || true
kubectl -n kube-system delete configmap kube-proxy 2>/dev/null || true

# Fix environment for Cilium CLI under cloud-init
export HOME=/root

# Install Cilium
cilium install \
  --version 1.19.1 \
  --set ipam.mode=eni \
  --set eni.enabled=true \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR="10.0.0.0/8" \
  --set kubeProxyReplacement=true \
  --set nodePort.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set eni.awsEnableInstanceTypeDetails=true \
  --set 'eni.nodeSpec.subnetTags[0]=cilium-pod-subnet=1'

echo "Waiting for Cilium to initialize..."
sleep 20
cilium status --wait || true

# Install AWS Node Termination Handler
echo "Installing AWS Node Termination Handler..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-node-termination-handler \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set enableRebalanceMonitoring=true \
  eks/aws-node-termination-handler


# ------ NEW: OpenEBS Install ------
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
