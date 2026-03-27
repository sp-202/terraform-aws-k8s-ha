#!/bin/bash
set -e

echo "Starting deployment of K3s Cluster on AWS (ASG Mode)..."

# Load local secrets (not tracked in git)
# Required: CF_TUNNEL_CREDENTIALS=<base64-encoded tunnel JSON>
#   Get it with: base64 -w0 ~/.cloudflared/<tunnel-id>.json
if [ -f secrets.env ]; then
  # shellcheck disable=SC1091
  source secrets.env
  echo "Loaded secrets.env"
else
  echo "WARNING: secrets.env not found."
  echo "  Create it with: echo \"CF_TUNNEL_CREDENTIALS=\$(base64 -w0 ~/.cloudflared/<tunnel-id>.json)\" > secrets.env"
  echo "  Cloudflared pods will need the secret created manually after bootstrap."
fi

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
echo "Phase 2: EKS Post-Cluster Bootstrap"
echo "---------------------------------------------------"
CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
POD_SUBNET_ID=$(terraform output -raw pod_subnet_id)

chmod +x ./scripts/post-cluster-bootstrap.sh
./scripts/post-cluster-bootstrap.sh "$CLUSTER_NAME" "$AWS_REGION" "$POD_SUBNET_ID" "${CF_TUNNEL_CREDENTIALS:-}"

echo "---------------------------------------------------"
echo "Deployment Complete!"
echo "---------------------------------------------------"
echo "EKS Cluster: $CLUSTER_NAME"
echo "Endpoint:    $(terraform output -raw eks_cluster_endpoint)"
echo ""
echo "Kubeconfig updated. Run:"
echo "  kubectl get nodes -o wide"
echo ""
echo "To see Worker IPs (Dynamic ASG):"
terraform output -raw worker_ips_command
echo ""
