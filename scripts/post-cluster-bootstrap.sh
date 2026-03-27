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

# Source secrets.env from repo root (works whether run directly or via deploy.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${REPO_ROOT}/secrets.env" ]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/secrets.env"
fi

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

# Fix exec credential apiVersion — older AWS CLI (<2.12) writes v1alpha1 which
# kubectl 1.24+ rejects. Force it to v1beta1 (supported by all kubectl 1.20+).
KUBECONFIG_FILE="${KUBECONFIG:-$HOME/.kube/config}"
if grep -q 'client.authentication.k8s.io/v1alpha1' "$KUBECONFIG_FILE" 2>/dev/null; then
  echo "  Fixing stale v1alpha1 apiVersion in kubeconfig (your AWS CLI needs updating)..."
  sed -i 's|client.authentication.k8s.io/v1alpha1|client.authentication.k8s.io/v1beta1|g' "$KUBECONFIG_FILE"
fi

echo "==> Waiting for EKS API server to become responsive..."
# EKS marks the cluster ACTIVE before the API endpoint DNS has fully propagated.
# Allow up to 10 minutes (60 × 10s). On each failure print the real error so
# connectivity problems (security group, DNS, IAM) are immediately visible.
for i in $(seq 1 60); do
  ERR=$(kubectl cluster-info 2>&1) && { echo "EKS API server is ready."; break; }
  if [ "$i" -eq 60 ]; then
    echo "ERROR: EKS API server not responsive after 10 minutes."
    echo "Last error: $ERR"
    echo ""
    echo "Common causes:"
    echo "  1. DNS not propagated yet — wait and retry"
    echo "  2. Your IP is blocked — check endpoint_public_access_cidrs in eks.tf"
    echo "  3. IAM — run: aws sts get-caller-identity"
    echo "  4. Private-only cluster — you need to be on VPN or inside the VPC"
    exit 1
  fi
  echo "  EKS API not ready yet (${i}/60): $(echo "$ERR" | tail -1)"
  sleep 10
done
kubectl cluster-info

# -------------------------------------------------------
# Step 2 — Node auth is handled by aws_eks_access_entry in Terraform
# (type = "EC2_LINUX" automatically grants system:nodes to the node IAM role)
# No aws-auth ConfigMap patching needed.
# -------------------------------------------------------

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
# Step 4 — Delete kube-proxy BEFORE Cilium (Cilium replaces it)
#
# With kubeProxyReplacement=true, kube-proxy must be gone first.
# Also remove the EKS addon so the addon controller doesn't recreate it.
# -------------------------------------------------------
echo "==> Deleting kube-proxy (will be replaced by Cilium kubeProxyReplacement)..."
kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found
kubectl -n kube-system delete configmap kube-proxy --ignore-not-found
aws eks delete-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name kube-proxy \
  --region "$AWS_REGION" 2>/dev/null && echo "kube-proxy addon removed" || echo "kube-proxy addon not present, skipping"

# -------------------------------------------------------
# Step 5 — Wait for at least one node, then install Cilium
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

# First attempt — if it fails with timeout (webhook not ready), clean up and retry
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
  --set eni.disableSourceDestCheck=true \
  --set "eni.subnetIDsFilter[0]=$POD_SUBNET_ID" || {
    echo "==> Cilium install failed. Cleaning up partial release and retrying..."
    # Delete any Cilium webhooks that block API calls when operator isn't running
    kubectl delete validatingwebhookconfiguration cilium --ignore-not-found
    kubectl delete mutatingwebhookconfiguration cilium --ignore-not-found
    # Purge the failed Helm release so upgrade --install starts fresh
    helm uninstall cilium -n kube-system 2>/dev/null || true
    sleep 10
    echo "==> Retrying Cilium install..."
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
      --set eni.disableSourceDestCheck=true \
      --set "eni.subnetIDsFilter[0]=$POD_SUBNET_ID"
  }

# -------------------------------------------------------
# Wait for Cilium — proper production sequencing
#
# Two race conditions exist if you just fire-and-forget after helm install:
#
# Race 1 — IPAM pool empty (available=0):
#   Cilium agents need IPs from the CiliumNode CRD pool.
#   The operator populates this pool by calling EC2 API to allocate
#   secondary IPs on ENIs. Agents that start before the operator
#   finishes just loop on "Waiting for IPs" forever.
#
# Race 2 — FailedMount (hubble-tls / clustermesh-secrets):
#   The DaemonSet mounts TLS secrets that the operator generates
#   on first startup. If a node schedules an agent pod before the
#   operator has written these secrets, the volume mount times out
#   and the pod enters CrashLoopBackOff.
#
# Correct sequence:
#   1. Operator deployment → 1/1 Running
#   2. hubble-server-certs secret exists (operator writes this)
#   3. All CiliumNode CRs show allocated IPs (IPAM pool populated)
#   4. Cilium DaemonSet rollout complete
# -------------------------------------------------------

echo "==> [Cilium 1/4] Waiting for cilium-operator deployment to be Ready..."
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s
echo "  cilium-operator is Ready."

echo "==> [Cilium 2/4] Waiting for hubble-server-certs secret (operator generates this)..."
for i in $(seq 1 60); do
  if kubectl -n kube-system get secret hubble-server-certs &>/dev/null; then
    echo "  hubble-server-certs secret exists."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: hubble-server-certs secret not created after 10 minutes."
    echo "  Check operator logs: kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-operator --tail=50"
    exit 1
  fi
  echo "  Waiting for hubble-server-certs... ($i/60)"
  sleep 10
done

echo "==> [Cilium 3/4] Waiting for CiliumNode IPAM pools to be populated on all nodes..."
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
for i in $(seq 1 60); do
  POPULATED=$(kubectl get ciliumnodes -o jsonpath='{range .items[*]}{.status.eni.enis}{"\n"}{end}' 2>/dev/null | grep -vc '^$' || true)
  if [ "$POPULATED" -ge "$NODE_COUNT" ] && [ "$NODE_COUNT" -gt 0 ]; then
    echo "  All $NODE_COUNT CiliumNode IP pools populated."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "WARNING: CiliumNode pools not fully populated after 10 minutes — proceeding anyway."
    echo "  Check: kubectl get ciliumnodes -o wide"
    break
  fi
  echo "  IPAM pools populated: $POPULATED/$NODE_COUNT... ($i/60)"
  sleep 10
done

echo "==> [Cilium 4/4] Waiting for all Cilium agent pods to be Ready..."
for i in $(seq 1 72); do
  TOTAL=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | wc -l)
  READY=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running"' | wc -l)
  if [ "$TOTAL" -gt 0 ] && [ "$READY" -eq "$TOTAL" ]; then
    echo "  All $TOTAL Cilium agent pod(s) are Ready."
    break
  fi
  if [ "$i" -eq 72 ]; then
    echo "ERROR: Cilium agents not all Ready after 12 minutes."
    echo "  Unhealthy pods:"
    kubectl get pods -n kube-system -l k8s-app=cilium --no-headers | awk '$2!="1/1" || $3!="Running"'
    echo "  Logs:"
    kubectl logs -n kube-system -l k8s-app=cilium --tail=20 2>&1 | tail -40
    exit 1
  fi
  echo "  Cilium agents: $READY/$TOTAL Ready... ($i/72)"
  sleep 10
done

# -------------------------------------------------------
# Step 5b — Fix CoreDNS forward to VPC DNS resolver
# Nodes run systemd-resolved (127.0.0.53) which forwards to cluster DNS,
# creating a loop. Forward to VPC DNS (base + 2) instead.
# -------------------------------------------------------
echo "==> Patching CoreDNS to forward to VPC DNS resolver..."
kubectl -n kube-system get configmap coredns -o yaml | \
  sed 's|forward . /etc/resolv.conf|forward . 10.0.0.2|' | \
  kubectl apply -f - || true
kubectl -n kube-system rollout restart deployment coredns || true
# Wait for CoreDNS to be healthy before proceeding — everything after this
# depends on DNS working (OpenEBS image pulls, ArgoCD git resolution, etc.)
kubectl -n kube-system rollout status deployment/coredns --timeout=180s || true

# -------------------------------------------------------
# Step 6 — Install AWS Node Termination Handler
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
# Step 7 — Install OpenEBS
# -------------------------------------------------------
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
# Step 8 — Deploy auto-label DaemonJob (replaces k8s-auto-label.service)
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
                  if kubectl label node "$NODE_NAME" "node-role.kubernetes.io/${ROLE}=" --overwrite 2>&1; then
                    echo "node/${NODE_NAME} labeled with node-role.kubernetes.io/${ROLE}"
                  else
                    echo "node/${NODE_NAME} label failed, will retry"
                  fi
                else
                  echo "node/${NODE_NAME} has no node-role label yet, will retry"
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
    verbs: ["get", "list", "patch", "update"]
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

# Apply node-role.kubernetes.io/ labels immediately from the bootstrap script.
# CRITICAL: We must wait until ALL worker nodes are Ready and labeled before
# ArgoCD syncs. Otherwise postgres/minio PVs with nodeAffinity can't schedule.
#
# Expected worker count = number of ASGs with desired_capacity > 0.
# We have 3 fixed ASGs (gp, spark, minio) each desired=1 → 3 workers total.
# Read dynamically so this works if ASG counts change.
EXPECTED_WORKER_COUNT=3

echo "==> Waiting for all ${EXPECTED_WORKER_COUNT} worker nodes to join and be Ready..."
for i in $(seq 1 120); do  # up to 20 minutes
  TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "control-plane\|master" | wc -l || echo 0)
  READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "control-plane\|master" | awk '$2=="Ready"' | wc -l || echo 0)
  if [ "$READY_COUNT" -ge "$EXPECTED_WORKER_COUNT" ]; then
    echo "  All ${EXPECTED_WORKER_COUNT} worker nodes are Ready (total joined: ${TOTAL_NODES})."
    break
  fi
  if [ "$i" -eq 120 ]; then
    echo "ERROR: Only ${READY_COUNT}/${EXPECTED_WORKER_COUNT} worker nodes Ready after 20 minutes."
    kubectl get nodes --no-headers
    exit 1
  fi
  echo "  Waiting for workers: ${READY_COUNT}/${EXPECTED_WORKER_COUNT} Ready... ($i/120)"
  sleep 10
done

echo "==> Applying node-role.kubernetes.io/ labels to all Ready worker nodes..."
for i in $(seq 1 36); do  # up to 6 minutes
  READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "control-plane\|master" | awk '$2=="Ready" {print "node/"$1}' || true)
  if [ -z "$READY_NODES" ]; then
    echo "  No Ready worker nodes yet... ($i/36)"
    sleep 10
    continue
  fi
  ALL_LABELED=true
  for NODE in $READY_NODES; do
    ROLE=$(kubectl get "$NODE" -o jsonpath='{.metadata.labels.node-role}' 2>/dev/null)
    if [ -n "$ROLE" ]; then
      kubectl label "$NODE" "node-role.kubernetes.io/${ROLE}=" --overwrite 2>&1 | grep -v "not labeled" || true
    else
      echo "  Node ${NODE} has no node-role label yet — kubelet may still be starting ($i/36)"
      ALL_LABELED=false
    fi
  done
  if $ALL_LABELED; then
    LABELED_COUNT=$(echo "$READY_NODES" | wc -w)
    if [ "$LABELED_COUNT" -ge "$EXPECTED_WORKER_COUNT" ]; then
      echo "  All ${LABELED_COUNT} worker nodes labeled successfully."
      break
    fi
  fi
  if [ "$i" -eq 36 ]; then
    echo "ERROR: Could not label all nodes after 6 minutes. Current state:"
    kubectl get nodes --show-labels --no-headers
    exit 1
  fi
  sleep 10
done
echo "Node labeling complete."

# -------------------------------------------------------
# Step 9 — Install ArgoCD (GitOps controller)
#
# ArgoCD continuously reconciles k8s-platform-v2 from git.
# All config (domains, images, tunnel ID) lives in global-config.env
# committed to the repo — no deploy-v2.sh needed for manifests.
#
# Secrets that cannot be in git must be pre-created here before
# ArgoCD's first sync so pods don't crashloop waiting for them:
#   - cloudflared-credentials  (tunnel JSON, namespace: cloudflare)
#
# Access: https://argocd.<CF_DOMAIN>  (routed via cloudflared → Traefik)
# Initial password: kubectl -n argocd get secret argocd-initial-admin-secret \
#                     -o jsonpath='{.data.password}' | base64 -d
# -------------------------------------------------------

# Step 9-pre: Pre-create the cloudflared-credentials Secret so the first
# ArgoCD sync doesn't leave cloudflared pods in CreateContainerConfigError.
# CF_TUNNEL_CREDENTIALS must be set in the environment (base64-encoded JSON
# from ~/.cloudflared/<tunnel-id>.json) or passed as the 4th argument.
CF_TUNNEL_CREDENTIALS="${4:-${CF_TUNNEL_CREDENTIALS:-}}"
CF_DOMAIN="${5:-${CF_DOMAIN:-}}"
if [ -n "$CF_TUNNEL_CREDENTIALS" ]; then
  echo "==> Pre-creating cloudflared-credentials Secret..."
  kubectl create namespace cloudflare 2>/dev/null || true
  CF_TUNNEL_CREDS_JSON=$(echo "$CF_TUNNEL_CREDENTIALS" | base64 -d)
  kubectl create secret generic cloudflared-credentials \
    --namespace cloudflare \
    --from-literal=credentials.json="$CF_TUNNEL_CREDS_JSON" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "cloudflared-credentials Secret created."
else
  echo "WARNING: CF_TUNNEL_CREDENTIALS not set — skipping cloudflared-credentials Secret."
  echo "         Cloudflared pods will stay in CreateContainerConfigError until you create it manually:"
  echo "         kubectl create secret generic cloudflared-credentials -n cloudflare \\"
  echo "           --from-literal=credentials.json='\$(cat ~/.cloudflared/<tunnel-id>.json)'"
fi

echo "==> Installing Traefik (required before ArgoCD sync — IngressRoute CRDs must exist)..."
helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo update traefik
helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --timeout 5m0s \
  --set "ports.web.port=80" \
  --set "ports.websecure.port=443" \
  --set "ports.traefik.port=9000" \
  --set "ports.metrics.port=9101" \
  --set "global.checkNewVersion=false" \
  --set "global.sendAnonymousUsage=false" \
  --set "additionalArguments[0]=--api.insecure=true" \
  --set "additionalArguments[1]=--api.dashboard=true" \
  --set "tolerations[0].key=node.cilium.io/agent-not-ready" \
  --set "tolerations[0].operator=Exists" \
  --set "tolerations[0].effect=NoSchedule" \
  --set "service.type=ClusterIP" \
  --set "ingressRoute.dashboard.enabled=false" \
  --set "securityContext.runAsUser=65532" \
  --set "securityContext.runAsGroup=65532" \
  --set "securityContext.runAsNonRoot=true" \
  --set "securityContext.readOnlyRootFilesystem=true" \
  --set "securityContext.allowPrivilegeEscalation=false" \
  --set "securityContext.capabilities.drop[0]=ALL" \
  --set "podSecurityContext.runAsUser=65532" \
  --set "podSecurityContext.runAsGroup=65532" \
  --set "podSecurityContext.runAsNonRoot=true"
kubectl patch svc traefik -n kube-system \
  -p '{"spec":{"ports":[{"name":"traefik","port":9000,"targetPort":8080}]}}' || true

echo "==> Pre-installing Prometheus Operator CRDs (ServiceMonitor, PodMonitor, etc.)..."
# cloudflared-servicemonitor.yaml uses ServiceMonitor CRD which is bundled inside
# kube-prometheus-stack helmChart (includeCRDs: true). ArgoCD applies all resources
# in a single wave — CRDs and CRs land at the same time which causes:
#   'no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"'
# Pre-installing CRDs here ensures they are registered before ArgoCD's first sync.
PROM_CRD_BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.71.2/example/prometheus-operator-crd"
for crd in \
  monitoring.coreos.com_alertmanagerconfigs.yaml \
  monitoring.coreos.com_alertmanagers.yaml \
  monitoring.coreos.com_podmonitors.yaml \
  monitoring.coreos.com_probes.yaml \
  monitoring.coreos.com_prometheusagents.yaml \
  monitoring.coreos.com_prometheuses.yaml \
  monitoring.coreos.com_prometheusrules.yaml \
  monitoring.coreos.com_scrapeconfigs.yaml \
  monitoring.coreos.com_servicemonitors.yaml \
  monitoring.coreos.com_thanosrulers.yaml; do
  kubectl apply --server-side -f "${PROM_CRD_BASE}/${crd}" 2>/dev/null || true
done
echo "Prometheus CRDs installed. Waiting for API registration..."
# Wait until the ServiceMonitor CRD is actually queryable — the API server
# registers CRDs asynchronously and a 5s sleep is not enough under load.
for i in $(seq 1 30); do
  if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
    echo "  ServiceMonitor CRD registered."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "WARNING: ServiceMonitor CRD not registered after 5 minutes — ArgoCD sync may fail on first attempt."
    break
  fi
  echo "  Waiting for CRD registration... ($i/30)"
  sleep 10
done

echo "==> Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || helm repo update argo
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 7.8.23 \
  --timeout 10m0s \
  --set server.extraArgs[0]="--insecure" \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set applicationSet.enabled=true \
  --set configs.cm."kustomize\.buildOptions"="--enable-helm"

echo "Waiting for ArgoCD server to become ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

# -------------------------------------------------------
# Step 9a — Create ArgoCD Application pointing at big-data-platform
#
# Uses HTTPS for the public repo — no deploy key needed.
# global-config.env in the repo is the single source of truth
# for all non-secret config (CF_DOMAIN, CF_TUNNEL_ID, images, etc.).
# The cloudflared-credentials Secret is managed out-of-band (Step 9-pre).
# -------------------------------------------------------
echo "==> Creating ArgoCD Application (big-data-platform)..."
kubectl apply -f - <<'ARGOEOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: big-data-platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/sp-202/cloud-native-bigdata-stack.git
    targetRevision: beta-aws
    path: big-data-platform
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    # cloudflared-credentials is pre-created out-of-band (Step 9-pre)
    # ArgoCD must not prune or diff this Secret's data
    - group: ""
      kind: Secret
      name: cloudflared-credentials
      namespace: cloudflare
      jsonPointers:
        - /data
ARGOEOF

echo ""
echo "=================================================="
echo "Post-cluster bootstrap complete!"
echo "=================================================="
echo "Run: kubectl get nodes -o wide"
echo "Run: kubectl -n kube-system get pods"
echo ""
_CF_DOMAIN="${CF_DOMAIN:-<CF_DOMAIN>}"
echo "ArgoCD:"
echo "  UI:      https://argocd.${_CF_DOMAIN}"
echo "  CLI:     argocd login argocd.${_CF_DOMAIN} --grpc-web"
echo "  Initial password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Next: ArgoCD will auto-sync k8s-platform-v2 from git."
echo "      Update k8s-platform-v2/04-configs/global-config.env in git to change any config."
echo ""
