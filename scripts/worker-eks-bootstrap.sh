#!/bin/bash
set -euxo pipefail

CLUSTER_NAME="__CLUSTER_NAME__"
AWS_REGION="__AWS_REGION__"
NODE_NAME="__NODE_NAME__"
EKS_ENDPOINT="__EKS_ENDPOINT__"
EKS_CA_DATA="__EKS_CA_DATA__"
CLUSTER_DNS="__CLUSTER_DNS__"

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

PRIVATE_DNS=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  -s http://169.254.169.254/latest/meta-data/local-hostname)

# Resolve AWS CLI path — kubeconfig exec credential needs the absolute path.
# AWS CLI v2 installs to /usr/local/bin/aws, some distros have /usr/bin/aws.
AWS_CLI_PATH=$(which aws 2>/dev/null || echo /usr/local/bin/aws)
if [ ! -x "$AWS_CLI_PATH" ]; then
  echo "FATAL: aws CLI not found at $AWS_CLI_PATH"
  exit 1
fi

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
      apiVersion: client.authentication.k8s.io/v1
      command: ${AWS_CLI_PATH}
      interactiveMode: Never
      args:
        - eks
        - get-token
        - --cluster-name
        - ${CLUSTER_NAME}
        - --region
        - ${AWS_REGION}
EOF

mkdir -p /var/lib/kubelet
cat > /var/lib/kubelet/config.yaml << EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
clusterDNS:
  - ${CLUSTER_DNS}
clusterDomain: cluster.local
cgroupDriver: systemd
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 2m0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
serverTLSBootstrap: true
systemReserved:
  cpu: 500m
  memory: 512Mi
kubeReserved:
  cpu: 500m
  memory: 512Mi
EOF

KUBELET_BIN=$(which kubelet 2>/dev/null || echo /usr/bin/kubelet)

NODE_IP=$(ip -j route get 8.8.8.8 | jq -r '.[0].prefsrc')

PROVIDER_ID="aws:///${AZ}/${INSTANCE_ID}"

ECR_CRED_BIN=$(which ecr-credential-provider 2>/dev/null || echo "")
ECR_CRED_ARGS=""
if [ -n "$ECR_CRED_BIN" ] && [ -x "$ECR_CRED_BIN" ]; then
  ECR_CRED_DIR=$(dirname "$ECR_CRED_BIN")
  mkdir -p /etc/kubernetes/credential-providers
  cat > /etc/kubernetes/credential-providers/ecr-credential-provider.yaml << CREDEOF
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.com.cn"
      - "*.dkr.ecr-fips.*.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
CREDEOF
  ECR_CRED_ARGS="--image-credential-provider-config=/etc/kubernetes/credential-providers/ecr-credential-provider.yaml --image-credential-provider-bin-dir=${ECR_CRED_DIR}"
else
  echo "WARN: ecr-credential-provider binary not found — pre-pulling EKS ECR images via ctr"
  ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION" 2>/dev/null || true)
  if [ -n "$ECR_PASSWORD" ]; then
    ECR_ACCOUNT="602401143452.dkr.ecr.${AWS_REGION}.amazonaws.com"
    K8S_MINOR=$(kubelet --version 2>/dev/null | grep -oP 'v\d+\.\d+' || echo "v1.34")
    ctr -n k8s.io image pull --user "AWS:${ECR_PASSWORD}" \
      "${ECR_ACCOUNT}/eks/coredns:v1.12.3-eksbuild.1" 2>/dev/null || true
  fi
fi

mkdir -p /etc/systemd/system/kubelet.service.d

cat > /etc/systemd/system/kubelet.service.d/20-eks.conf << EOF
[Service]
ExecStart=
ExecStart=${KUBELET_BIN} --config=/var/lib/kubelet/config.yaml --hostname-override=${PRIVATE_DNS} --provider-id=${PROVIDER_ID} --node-ip=${NODE_IP} --node-labels=node-role=${NODE_NAME} --container-runtime-endpoint=unix:///run/containerd/containerd.sock --kubeconfig=/etc/kubernetes/kubelet/kubeconfig.yaml ${ECR_CRED_ARGS}
EOF

systemctl daemon-reload
systemctl enable kubelet
systemctl restart kubelet

echo "EKS worker bootstrap complete. Node: ${PRIVATE_DNS} (role: ${NODE_NAME})"
