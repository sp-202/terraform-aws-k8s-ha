#!/bin/bash
set -e

echo "Fetching Master Public IP from Terraform..."
MASTER_IP=$(terraform output -raw master_public_ip)

if [ -z "$MASTER_IP" ]; then
  echo "Error: Master IP not found. Did you run 'terraform apply'?"
  exit 1
fi

echo "Master IP: $MASTER_IP"
echo "Waiting for SSH to become available..."

# Wait up to 300 seconds for SSH
count=0
while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$MASTER_IP "echo 'SSH Ready'" &>/dev/null; do
  echo "Waiting for master to be reachable via SSH..."
  sleep 10
  count=$((count+1))
  if [ $count -ge 30 ]; then
     echo "Timeout waiting for SSH."
     exit 1
  fi
done

echo "SSH is ready. Fetching Kubeconfig..."

# Try to fetch config with retries (in case k3s is still installing)
count=0
while ! scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@$MASTER_IP:/home/ubuntu/.kube/config ./k3s.yaml &>/dev/null; do
  echo "Waiting for k3s config to be available on master..."
  sleep 10
  count=$((count+1))
  if [ $count -ge 30 ]; then
    echo "Timeout waiting for k3s config."
    exit 1
  fi
done

# Replace localhost with public IP
sed -i "s/127.0.0.1/$MASTER_IP/g" k3s.yaml
chmod 600 k3s.yaml

echo "Kubeconfig saved to ./k3s.yaml"
echo "You can use it with:"
echo "export KUBECONFIG=$(pwd)/k3s.yaml"
echo "kubectl get nodes"
