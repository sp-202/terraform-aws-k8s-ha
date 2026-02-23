# High-Performance Kubernetes 1.34 Cluster on AWS (ARM64)

This repository provides a production-ready, automated setup for a **Kubernetes 1.34 HA Cluster** on AWS, optimized for data-intensive workloads like Spark and MinIO. It leverages **Infrastructure as Code (Terraform)**, **Golden AMIs (Packer)**, and **NVMe RAID 0** storage for maximum performance.

## 🏗 Key Features & Architecture

### 1. Advanced Networking & Load Balancing
- **Cilium CNI**: High-performance networking with eBPF and Hubble observability.
- **MetalLB**: Layer 2 load balancing for on-premise style external IP management.
- **AWS Node Termination Handler**: Gracefully handles Spot Instance interruptions.

### 2. High-Performance Storage
- **Automatic NVMe Discovery**: Dynamically identifies local instance store disks.
- **RAID 0 Optimization**: Automatically strips multiple NVMe drives into a RAID 0 array for massive IOPS/throughput.
- **OpenEBS**: Local provisioner for dynamic `StorageClass` management using local high-speed disks.

### 3. Golden AMI Optimization
- Uses **Packer** to pre-bake all heavy dependencies (`containerd 2.0`, `kubeadm`, `cilium`, `helm`) into the AMI.
- Drastically reduces instance boot time (User Data only handles runtime configuration, no package installs).

### 4. Specialized Node Roles (Auto-Labeled)
The cluster automatically labels nodes based on their purpose:
- **GP Nodes**: General purpose worker nodes.
- **Spark Nodes**: Dedicated nodes for Spark critical/spot workloads.
- **MinIO Nodes**: Optimized for S3-compatible object storage.

## 🚀 Deployment

### Prerequisites
- [AWS CLI](https://aws.amazon.com/cli/) configured.
- [Packer](https://www.packer.io/) installed.
- [Terraform](https://www.terraform.io/) installed.

### 1. Build the Golden AMI
```bash
cd packer
packer init .
packer build k8s-golden-ami.pkr.hcl
```

### 2. Provision the Cluster
```bash
# Return to root directory
chmod +x deploy.sh
./deploy.sh
```

The script will automatically provision the VPC, Master Node, and multiple Auto Scaling Groups, then fetch the `kubeconfig` to your local machine.

## 🔧 Post-Deployment
Access the cluster:
```bash
export KUBECONFIG=$(pwd)/k3s.yaml
kubectl get nodes
```

## 📂 Repository Structure
- `packer/`: Golden AMI configuration and initialization scripts.
- `scripts/`: specialized runtime scripts (`common-runtime.sh`, `master-runtime.sh`).
- `compute-*.tf`: Specialized compute modules for different node roles.
- `issues.md`: Detailed history of technical troubleshooting and resolutions.

## 🛠 Management & Scale
- **Scaling**: Simply update the `min_size`/`max_size` in the respective `compute-*.tf` files.
- **Security Check**: Master nodes are accessible via Public IP (SSH), while Workers are in Private subnets (access via Jump Host).
