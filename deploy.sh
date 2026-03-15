#!/bin/bash
set -e

echo "Starting deployment of K3s Cluster on AWS (ASG Mode)..."

echo "---------------------------------------------------"
echo "Phase 1: Provisioning Infrastructure with Terraform"
echo "---------------------------------------------------"
terraform init

PS3="Select action: "
actions=("deploy-dev" "deploy-prod" "destroy-dev" "destroy-prod" "quit")

select ACTION in "${actions[@]}"; do
  case $ACTION in
    deploy-dev)
      echo "Deploying to dev environment..."
      terraform apply -var-file="dev.tfvars" --auto-approve
      break
      ;;
    deploy-prod)
      echo "⚠️  Deploying to PROD environment..."
      read -p "Are you sure? (y/n): " confirm
      [[ "$confirm" == "y" ]] || { echo "Aborted."; exit 1; }
      terraform apply -var-file="prod.tfvars" --auto-approve
      break
      ;;
    destroy-dev)
      echo "⚠️  Destroying dev environment..."
      read -p "Are you sure? (y/n): " confirm
      [[ "$confirm" == "y" ]] || { echo "Aborted."; exit 1; }
      terraform destroy -var-file="dev.tfvars" --auto-approve
      exit 0
      break
      ;;
    destroy-prod)
      echo "🚨 Destroying PROD environment — this is irreversible!"
      read -p "Type 'destroy-prod' to confirm: " confirm
      [[ "$confirm" == "destroy-prod" ]] || { echo "Aborted."; exit 1; }
      terraform destroy -var-file="prod.tfvars" --auto-approve
      exit 0
      break
      ;;
    quit)
      echo "Exiting."
      exit 0
      ;;
    *)
      echo "Invalid option. Try again."
      ;;
  esac
done

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
