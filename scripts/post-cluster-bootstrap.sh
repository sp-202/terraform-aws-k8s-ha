#!/bin/bash
# -------------------------------------------------------
# Post-Cluster Bootstrap for EKS Self-Managed Nodes
#
# Run this ONCE after `terraform apply` from your local machine.
# Replaces what master-runtime.sh used to do on the master node.
#
# Prerequisites on your local machine:
#   - aws cli (configured, same profile as terraform)
#   - kubectl
#   - helm
# -------------------------------------------------------

set -euxo pipefail

CLUSTER_NAME="${1:-k8s-ha-cluster}"
AWS_REGION="${2:-us-east-1}"
POD_SUBNET_ID="${3:-}"  # pass as 3rd arg or set below via terraform output

if [ -z "$POD_SUBNET_ID" ]; then
  echo "Fetching pod subnet ID from terraform output..."
  POD_SUBNET_ID=$(terraform output -raw pod_subnet_id 2>/dev/null || true)
  if [ -z "$POD_SUBNET_ID" ]; then
    echo "ERROR: POD_SUBNET_ID is required. Pass it as 3rd argument or add pod_subnet_id to outputs.tf"
    exit 1
  fi
fi

# -------------------------------------------------------
# Step 1 — Update local kubeconfig and wait for EKS API
# -------------------------------------------------------
echo "==> Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo "==> Waiting for EKS API server to become responsive..."
for i in $(seq 1 30); do
  if kubectl cluster-info >/dev/null 2>&1; then
    echo "EKS API server is ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: EKS API server not responsive after 5 minutes. Aborting."
    exit 1
  fi
  echo "  EKS API not ready yet, retrying... (${i}/30)"
  sleep 10
done
kubectl cluster-info

# -------------------------------------------------------
# Step 2 — Authorise worker nodes (aws-auth ConfigMap)
# Workers use the node IAM role — EKS must map it to system:bootstrappers
# -------------------------------------------------------
echo "==> Patching aws-auth ConfigMap to allow self-managed nodes to register..."

NODE_ROLE_ARN=$(aws iam get-role \
  --role-name "${CLUSTER_NAME}-node-role" \
  --query 'Role.Arn' --output text)

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${NODE_ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

# -------------------------------------------------------
# Step 3 — REMOVE aws-node (VPC CNI) BEFORE installing Cilium
#
# EKS creates aws-node DaemonSet automatically on every cluster.
# Cilium in ENI mode also manages ENIs and secondary IP allocation directly.
# If both run at the same time they will:
#   - Double-allocate secondary IPs on the same ENI
#   - Write conflicting ip rules / route tables on the node
#   - Cause random pods to get wrong routes → CrashLoopBackOff
#   - Nodes go NotReady with "failed to allocate IP" errors
#
# Order matters: delete aws-node FIRST, wait for pods to terminate,
# THEN install Cilium. Never the other way around.
# -------------------------------------------------------
echo "==> Removing aws-node (VPC CNI) to avoid ENI conflict with Cilium..."

# Delete the DaemonSet — this stops aws-node from running on any node
kubectl -n kube-system delete daemonset aws-node --ignore-not-found

# Delete the aws-node ServiceAccount and ClusterRole so it cannot be re-created
# by the EKS addon controller if it somehow restarts
kubectl -n kube-system delete serviceaccount aws-node --ignore-not-found
kubectl delete clusterrole aws-node --ignore-not-found
kubectl delete clusterrolebinding aws-node --ignore-not-found

# Wait until every aws-node pod is fully terminated before proceeding.
# Cilium must not start while aws-node pods are still running — even
# a terminating aws-node pod can race Cilium on ENI secondary IP release.
echo "Waiting for aws-node pods to fully terminate..."
for i in $(seq 1 30); do
  COUNT=$(kubectl -n kube-system get pods -l k8s-app=aws-node --no-headers 2>/dev/null | wc -l)
  if [ "$COUNT" -eq 0 ]; then
    echo "aws-node fully removed."
    break
  fi
  echo "  Still ${COUNT} aws-node pod(s) running, waiting... (${i}/30)"
  sleep 5
done

# Also remove the aws-vpc-cni EKS addon if it was registered
# (suppresses the addon controller from re-adding aws-node after cluster upgrades)
aws eks delete-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name vpc-cni \
  --region "$AWS_REGION" 2>/dev/null && echo "vpc-cni addon removed" || echo "vpc-cni addon not present, skipping"

# -------------------------------------------------------
# Step 4 — Wait for at least one node, then install Cilium
#
# Key differences from the old kubeadm setup:
#   - k8sServiceHost is the EKS endpoint hostname (not master private IP)
#   - k8sServicePort is 443 (EKS API server listens on 443, not 6443)
#   - No eni.excludeNodeLabelKey needed — there is no control-plane node
# -------------------------------------------------------
echo "==> Waiting for at least one worker node to register..."
for i in $(seq 1 60); do
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  if [ "$NODE_COUNT" -ge 1 ]; then
    echo "  ${NODE_COUNT} node(s) registered. Proceeding with Cilium install."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: No nodes registered after 10 minutes. Installing Cilium anyway (DaemonSet will schedule when nodes join)."
  fi
  echo "  No nodes yet, waiting... (${i}/60)"
  sleep 10
done

echo "==> Installing Cilium..."

EKS_ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.endpoint' --output text | sed 's|https://||')

helm repo add cilium https://helm.cilium.io/ 2>/dev/null || helm repo update cilium
helm repo update

helm upgrade --install cilium cilium/cilium \
  --version 1.19.1 \
  --namespace kube-system \
  --timeout 10m0s \
  --set ipam.mode=eni \
  --set eni.enabled=true \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR="10.0.0.0/8" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$EKS_ENDPOINT" \
  --set k8sServicePort=443 \
  --set socketLB.hostNamespaceOnly=false \
  --set enableIPv4Masquerade=true \
  --set bpf.masquerade=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set eni.awsEnableInstanceTypeDetails=true \
  --set eni.updateEC2AdapterLimitViaAPI=true \
  --set eni.awsReleaseExcessIPs=true \
  --set "eni.subnetIDsFilter[0]=$POD_SUBNET_ID"

echo "Waiting for Cilium to initialize..."
sleep 30
kubectl -n kube-system rollout status daemonset/cilium --timeout=180s || true

# -------------------------------------------------------
# Step 4b — Delete kube-proxy (Cilium replaces it)
# -------------------------------------------------------
echo "==> Deleting kube-proxy (replaced by Cilium kubeProxyReplacement)..."
kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found
kubectl -n kube-system delete configmap kube-proxy --ignore-not-found

# -------------------------------------------------------
# Step 4c — Fix CoreDNS forward to VPC DNS resolver
# Nodes run systemd-resolved (127.0.0.53) which forwards to cluster DNS,
# creating a loop. Forward to VPC DNS (base + 2) instead.
# -------------------------------------------------------
echo "==> Patching CoreDNS to forward to VPC DNS resolver..."
kubectl -n kube-system get configmap coredns -o yaml | \
  sed 's|forward . /etc/resolv.conf|forward . 10.0.0.2|' | \
  kubectl apply -f - || true
kubectl -n kube-system rollout restart deployment coredns || true

# -------------------------------------------------------
# Step 5 — Install AWS Node Termination Handler
# -------------------------------------------------------
echo "==> Installing AWS Node Termination Handler..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || helm repo update eks
helm repo update
helm upgrade --install aws-node-termination-handler \
  --namespace kube-system \
  --timeout 5m0s \
  --set enableSpotInterruptionDraining=true \
  --set enableRebalanceMonitoring=true \
  eks/aws-node-termination-handler

# -------------------------------------------------------
# Step 6 — Install OpenEBS
# -------------------------------------------------------
echo "Waiting for I/O to settle before OpenEBS install..."
sleep 30

echo "==> Installing OpenEBS..."
helm repo add openebs https://openebs.github.io/openebs 2>/dev/null || helm repo update openebs
helm repo update
helm upgrade --install openebs openebs/openebs \
  --namespace openebs --create-namespace \
  --timeout 5m0s \
  --set engines.replicated.mayastor.enabled=false \
  --set engines.local.zfs.enabled=false \
  --set engines.local.lvm.enabled=false || true

# -------------------------------------------------------
# Step 7 — Deploy auto-label DaemonJob (replaces k8s-auto-label.service)
# On EKS we can't run a systemd service on the control plane,
# so we run a lightweight DaemonSet that labels nodes by name pattern.
# -------------------------------------------------------
echo "==> Deploying node auto-labeler..."

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-auto-labeler
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: node-auto-labeler
  template:
    metadata:
      labels:
        app: node-auto-labeler
    spec:
      serviceAccountName: node-auto-labeler
      tolerations:
        - operator: Exists
      containers:
        - name: labeler
          image: bitnami/kubectl:latest
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                ROLE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node-role}' 2>/dev/null)
                if [ -n "$ROLE" ]; then
                  kubectl label node "$NODE_NAME" "node-role.kubernetes.io/${ROLE}=" --overwrite 2>/dev/null || true
                fi
                sleep 30
              done
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-auto-labeler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-auto-labeler
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-auto-labeler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-auto-labeler
subjects:
  - kind: ServiceAccount
    name: node-auto-labeler
    namespace: kube-system
EOF

echo ""
echo "=================================================="
echo "Post-cluster bootstrap complete!"
echo "=================================================="
echo "Run: kubectl get nodes -o wide"
echo "Run: kubectl -n kube-system get pods"
echo ""
