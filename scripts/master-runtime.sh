#!/bin/bash

set -euxo pipefail

PUBLIC_IP_ACCESS="false"
NODENAME=$(hostname -s)

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
    ADVERTISE_ADDRESS="$MASTER_PRIVATE_IP"
    CERT_SANS="$MASTER_PUBLIC_IP,$MASTER_PRIVATE_IP,127.0.0.1,localhost"
else
    echo "Error: PUBLIC_IP_ACCESS has an invalid value: $PUBLIC_IP_ACCESS"
    exit 1
fi

cat > /tmp/kubeadm-config.yaml << KUBEADM_EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: "__POD_CIDR__"
  serviceSubnet: "10.96.0.0/12"
apiServer:
  certSANs:
$(for san in $(echo $CERT_SANS | tr ',' ' '); do echo "    - $san"; done)
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: heartbeat-interval
        value: "250"
      - name: election-timeout
        value: "2500"
      - name: quota-backend-bytes
        value: "1073741824"
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

sudo kubeadm init --config /tmp/kubeadm-config.yaml --skip-phase=addon/kube-proxy

USER_HOME="/home/ubuntu"
USER_ID=$(id -u ubuntu)
GROUP_ID=$(id -g ubuntu)

mkdir -p "$USER_HOME"/.kube
sudo cp /etc/kubernetes/admin.conf "$USER_HOME"/.kube/config
sudo chown "$USER_ID":"$GROUP_ID" "$USER_HOME"/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf
export HOME=/root

kubectl -n kube-system delete daemonset kube-proxy 2>/dev/null || true
kubectl -n kube-system delete configmap kube-proxy 2>/dev/null || true
kubectl delete clusterrolebinding kube-proxy 2>/dev/null || true
kubectl delete serviceaccount kube-proxy -n kube-system 2>/dev/null || true

helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --version 1.16.5 \
  --namespace kube-system \
  --set ipam.mode=eni \
  --set eni.enabled=true \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR="10.0.0.0/8" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$MASTER_PRIVATE_IP" \
  --set k8sServicePort=6443 \
  --set socketLB.hostNamespaceOnly=false \
  --set bpf.masquerade=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set eni.awsEnableInstanceTypeDetails=true \
  --set eni.updateEC2AdapterLimitViaAPI=true \
  --set eni.awsReleaseExcessIPs=true \
  --set eni.subnetIDsFilter[0]="__POD_SUBNET_ID__" \

echo "Waiting for Cilium to initialize..."
sleep 30

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-node-termination-handler \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set enableRebalanceMonitoring=true \
  eks/aws-node-termination-handler

echo "Waiting for I/O to settle before OpenEBS install..."
sleep 30

helm repo add openebs https://openebs.github.io/openebs
helm repo update
helm upgrade --install openebs openebs/openebs \
  --namespace openebs --create-namespace \
  --set engines.replicated.mayastor.enabled=false \
  --set engines.local.zfs.enabled=false \
  --set engines.local.lvm.enabled=false

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