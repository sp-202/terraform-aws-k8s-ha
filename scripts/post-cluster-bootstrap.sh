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
# Step 1 — Update local kubeconfig
# -------------------------------------------------------
echo "==> Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
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
# Step 4 — Install Cilium
#
# Key differences from the old kubeadm setup:
#   - k8sServiceHost is the EKS endpoint hostname (not master private IP)
#   - k8sServicePort is 443 (EKS API server listens on 443, not 6443)
#   - No eni.excludeNodeLabelKey needed — there is no control-plane node
# -------------------------------------------------------
echo "==> Installing Cilium..."

EKS_ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.endpoint' --output text | sed 's|https://||')

helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
  --version 1.16.5 \
  --namespace kube-system \
  --set ipam.mode=eni \
  --set eni.enabled=true \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR="10.0.0.0/8" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$EKS_ENDPOINT" \
  --set k8sServicePort=443 \
  --set socketLB.hostNamespaceOnly=false \
  --set bpf.masquerade=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set eni.awsEnableInstanceTypeDetails=true \
  --set eni.updateEC2AdapterLimitViaAPI=true \
  --set eni.awsReleaseExcessIPs=true \
  --set "eni.subnetIDsFilter[0]=$POD_SUBNET_ID"

echo "Waiting for Cilium to initialize..."
sleep 30
kubectl -n kube-system rollout status daemonset/cilium --timeout=120s || true

# -------------------------------------------------------
# Step 5 — Install AWS Node Termination Handler
# -------------------------------------------------------
echo "==> Installing AWS Node Termination Handler..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-node-termination-handler \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set enableRebalanceMonitoring=true \
  eks/aws-node-termination-handler

# -------------------------------------------------------
# Step 6 — Install OpenEBS
# -------------------------------------------------------
echo "Waiting for I/O to settle before OpenEBS install..."
sleep 30

echo "==> Installing OpenEBS..."
helm repo add openebs https://openebs.github.io/openebs
helm repo update
helm upgrade --install openebs openebs/openebs \
  --namespace openebs --create-namespace \
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
      hostPID: true
      serviceAccountName: node-auto-labeler
      tolerations:
        - operator: Exists
      containers:
        - name: labeler
          image: bitnami/kubectl:latest
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                NODE=$(cat /etc/hostname)
                case "$NODE" in
                  spark-worker-*) kubectl label node "$NODE" node-role.kubernetes.io/spark-worker='' --overwrite 2>/dev/null || true ;;
                  minio-worker-*) kubectl label node "$NODE" node-role.kubernetes.io/minio-worker='' --overwrite 2>/dev/null || true ;;
                  spark-node-*)   kubectl label node "$NODE" node-role.kubernetes.io/spark-node='' --overwrite 2>/dev/null || true ;;
                  k8s-gp-node-*)  kubectl label node "$NODE" node-role.kubernetes.io/k8s-gp-node='' --overwrite 2>/dev/null || true ;;
                esac
                sleep 30
              done
          volumeMounts:
            - name: hostname
              mountPath: /etc/hostname
              readOnly: true
      volumes:
        - name: hostname
          hostPath:
            path: /etc/hostname
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
