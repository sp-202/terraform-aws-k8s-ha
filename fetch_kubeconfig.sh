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

count=0
while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$MASTER_IP "echo 'SSH Ready'" &>/dev/null; do
  echo "Waiting for master to be reachable via SSH..."
  sleep 10
  count=$((count+1))
  if [ $count -ge 30 ]; then
    echo "Timeout waiting for SSH."
    exit 1
  fi
done

echo "SSH is ready."

# Wait for kubeadm to finish - admin.conf won't exist until init completes
echo "Waiting for kubeadm init to complete..."
count=0
while ! ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@$MASTER_IP \
  "test -f /home/ubuntu/.kube/config" &>/dev/null; do
  echo "Waiting for kubeconfig to be generated..."
  sleep 15
  count=$((count+1))
  if [ $count -ge 40 ]; then
    echo "Timeout waiting for kubeconfig. Check /var/log/user-data.log on master."
    exit 1
  fi
done

echo "Fetching kubeconfig..."
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 \
  ubuntu@$MASTER_IP:/home/ubuntu/.kube/config ./kubeconfig.yaml

# Replace whatever server address kubeadm wrote with the actual public IP
# kubeadm puts the private IP or 0.0.0.0 - we need the public IP
CURRENT_SERVER=$(grep "server:" ./kubeconfig.yaml | awk '{print $2}')
echo "Current server in kubeconfig: $CURRENT_SERVER"

sed -i "s|server: https://.*:6443|server: https://$MASTER_IP:6443|g" ./kubeconfig.yaml
chmod 600 ./kubeconfig.yaml

echo ""
echo "Kubeconfig saved to ./kubeconfig.yaml"
echo "Verify the server address was patched:"
grep "server:" ./kubeconfig.yaml
echo ""
echo "Use it with:"
echo "  export KUBECONFIG=$(pwd)/kubeconfig.yaml"
echo "  kubectl get nodes"