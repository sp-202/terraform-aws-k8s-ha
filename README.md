# AWS K3s Cluster with Terraform

A professional-grade Terraform setup to deploy a highly available **K3s Kubernetes Cluster** on AWS.

## 🏗 Architecture
- **VPC & Networking**: Custom VPC with Public and Private subnets across multiple Availability Zones (`us-east-1a`, `us-east-1b`, `us-east-1c`).
- **Master Node**: 
  - On-Demand Instance (`c5.2xlarge`) in Public Subnet.
  - Acts as Control Plane and SSH Bastion.
  - Self-healing: Recreates automatically if startup configuration changes.
- **Worker Nodes**: 
  - **Auto Scaling Group (ASG)** spanning multiple AZs.
  - **Spot Instances** (`r5.2xlarge`, `r5d.2xlarge`, `m5.2xlarge`, etc.) for cost optimization.
  - Private networking with NAT Gateway for secure internet access.
- **Security**: 
  - Least-privilege Security Groups.
  - SSH access restricted to Key Pair.

## 🚀 Quick Start

### Prerequisites
- [AWS CLI](https://aws.amazon.com/cli/) configured with `us-east-1` region.
- [Terraform](https://www.terraform.io/) installed (v1.0+).
- `kubectl` installed locally.
- SSH Public Key at `~/.ssh/id_rsa.pub` (or update `variables.tf`).

### Deployment
Run the automated deployment script:

```bash
chmod +x deploy.sh
./deploy.sh
```

This script will:
1. Provision infrastructure with Terraform.
2. Wait for the Master node to initialize.
3. Download the `k3s.yaml` kubeconfig to your local directory.

### Accessing the Cluster
Once deployed, set your kubeconfig:

```bash
export KUBECONFIG=$(pwd)/k3s.yaml
kubectl get nodes
```

## 🔧 Management

### SSH Access
**To Master:**
```bash
# Get Master IP
terraform output master_public_ip

# SSH
ssh -i ~/.ssh/id_rsa ubuntu@<MASTER_IP>
```

**To Workers (via Jump Host):**
Get the dynamic worker IPs:
```bash
terraform output worker_ips_command | bash
```
Then proxy-jump:
```bash
ssh -J ubuntu@<MASTER_IP> ubuntu@<WORKER_PRIVATE_IP>
```

### Destruction
To tear down the cluster and stop billing:

```bash
terraform destroy -auto-approve
```

## 📂 File Structure
- `compute.tf`: EC2 instances, ASG, Launch Templates.
- `network.tf`: VPC, Subnets, NAT Gateway, Route Tables.
- `security.tf`: Security Groups.
- `variables.tf`: Configuration variables.
- `outputs.tf`: Terraform outputs.
- `deploy.sh`: Orchestration script.
