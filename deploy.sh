#!/bin/bash
set -e

echo "Starting deployment of K3s Cluster on AWS (ASG Mode)..."

echo "---------------------------------------------------"
echo "Phase 1: Provisioning Infrastructure with Terraform"
echo "---------------------------------------------------"
terraform init
terraform apply -auto-approve

echo "---------------------------------------------------"
echo "Phase 2: Verifying Cluster and Fetching Kubeconfig"
echo "---------------------------------------------------"
./fetch_kubeconfig.sh

echo "---------------------------------------------------"
echo "Deployment Complete!"
echo "---------------------------------------------------"
echo "Master Public IP: $(terraform output -raw master_public_ip)"
echo ""
echo "To see Worker IPs (Dynamic ASG):"
terraform output -raw worker_ips_command
echo ""
KUBE_EXPORT="export KUBECONFIG=$(pwd)/k3s.yaml"
if ! grep -qF "$KUBE_EXPORT" ~/.bashrc; then
    echo "$KUBE_EXPORT" >> ~/.bashrc
    echo "Successfully added KUBECONFIG to ~/.bashrc"
fi
export KUBECONFIG=$(pwd)/k3s.yaml
echo "Use 'kubectl get nodes' to verify the cluster."
