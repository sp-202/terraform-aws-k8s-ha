#!/bin/bash
# -------------------------------------------------------
# EKS Self-Managed Node Bootstrap
# Replaces: kubeadm join
# How it works:
#   1. common-runtime.sh already ran (NVMe, sysctl, kubelet config)
#   2. This script patches kubelet with EKS cluster details
#   3. Uses aws-eks-bootstrap approach: sets --node-name, --provider-id
#      and writes /etc/kubernetes/kubelet/kubeconfig pointing at EKS endpoint
# -------------------------------------------------------

set -euxo pipefail

CLUSTER_NAME="__CLUSTER_NAME__"
AWS_REGION="__AWS_REGION__"
NODE_NAME="__NODE_NAME__"
EKS_ENDPOINT="__EKS_ENDPOINT__"
EKS_CA_DATA="__EKS_CA_DATA__"

# Fetch instance metadata (IMDSv2)
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Disable source/dest check — required for Cilium ENI mode
aws ec2 modify-instance-attribute \
  --instance-id "$INSTANCE_ID" \
  --no-source-dest-check \
  --region "$AWS_REGION"

# Write EKS CA cert
mkdir -p /etc/kubernetes/pki
echo "$EKS_CA_DATA" | base64 -d > /etc/kubernetes/pki/ca.crt

# Write kubelet kubeconfig pointing at EKS managed endpoint
mkdir -p /etc/kubernetes/kubelet
cat > /etc/kubernetes/kubelet/kubeconfig.yaml << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: ${EKS_ENDPOINT}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: kubelet
  name: kubelet
current-context: kubelet
users:
- name: kubelet
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args:
        - eks
        - get-token
        - --cluster-name
        - ${CLUSTER_NAME}
        - --region
        - ${AWS_REGION}
EOF

# Write kubelet extra args — node name, provider ID, cloud provider
PROVIDER_ID="aws:///${AZ}/${INSTANCE_ID}"
mkdir -p /etc/systemd/system/kubelet.service.d

cat > /etc/systemd/system/kubelet.service.d/20-eks.conf << EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=\
  --node-name=${NODE_NAME}-${INSTANCE_ID} \
  --provider-id=${PROVIDER_ID} \
  --kubeconfig=/etc/kubernetes/kubelet/kubeconfig.yaml \
  --bootstrap-kubeconfig=/etc/kubernetes/kubelet/kubeconfig.yaml \
  --cloud-provider=external"
EOF

systemctl daemon-reload
systemctl enable kubelet
systemctl restart kubelet

echo "EKS worker bootstrap complete. Node: ${NODE_NAME}-${INSTANCE_ID}"
