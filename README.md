# terraform-aws-k8s-ha

**Production-ready, high-availability Kubernetes 1.34 cluster on AWS ARM64 (Graviton), optimized for data-intensive workloads.**

Built with Terraform, Packer-baked Golden AMIs, Cilium eBPF networking, and automatic NVMe RAID 0 storage — designed from the ground up for Spark, MinIO, and general workloads at scale.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Component Versions](#component-versions)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment Guide](#deployment-guide)
- [Repository Structure](#repository-structure)
- [Node Roles](#node-roles)
- [Networking](#networking)
- [Storage](#storage)
- [Golden AMI Pipeline](#golden-ami-pipeline)
- [Security](#security)
- [Scaling](#scaling)
- [Troubleshooting](#troubleshooting)

---

## Overview

This repository automates the full lifecycle of a multi-node Kubernetes HA cluster on AWS. It is opinionated and purpose-built for workloads that demand high IOPS, low-latency networking, and cost-aware elasticity via Spot instances.

**Key design goals:**

- ARM64-first (AWS Graviton) for price/performance efficiency
- Golden AMI strategy to minimize bootstrap time
- Fully automated node joining — no manual steps after `terraform apply`
- Cilium CNI with AWS ENI IPAM for pod-level network isolation
- Automatic NVMe detection and RAID 0 setup for maximum local storage performance
- Environment parity between dev and prod via tfvars

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          AWS VPC (10.0.0.0/16)                  │
│                                                                 │
│  ┌─────────────────────────────────┐                            │
│  │     Public Subnet (10.0.1.0/24) │                            │
│  │  ┌───────────────────────────┐  │                            │
│  │  │  Master Node (c7g.2xlarge)│  │◄─── SSH / kubectl (6443)   │
│  │  │  - kubeadm control plane  │  │                            │
│  │  │  - etcd (dedicated EBS)   │  │                            │
│  │  │  - Cilium agent           │  │                            │
│  │  └───────────────────────────┘  │                            │
│  └─────────────────────────────────┘                            │
│              │ kubeadm join token                               │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │           Private Subnet (10.0.2.0/24)                  │    │
│  │                                                         │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │    │
│  │  │  GP Workers  │  │ Spark Nodes  │  │ MinIO Nodes  │   │    │
│  │  │ (im4gn.4xl)  │  │ (i4g.8xlarge)│  │(im4gn.8xlarge│   │    │
│  │  │  ASG: 1-4    │  │  Critical +  │  │  NVMe RAID0  │   │    │
│  │  │  NVMe RAID0  │  │  Spot Fleet  │  │  Object Store│   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘   │    │
│  └─────────────────────────────────────────────────────────┘    │
│              │                                                  │
│  ┌───────────────────────────┐                                  │
│  │  Pod Subnet (10.0.4.0/24) │ ◄─── Cilium ENI IPAM             │
│  └───────────────────────────┘                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Traffic flow:**
- Inbound SSH and Kubernetes API (port 6443) via master's public IP
- Worker nodes egress through a NAT Gateway (private subnet)
- Pod-to-pod traffic managed by Cilium using secondary ENI IPs from the pod subnet
- MetalLB handles external IP assignment for LoadBalancer services (Layer 2)

---

## Component Versions

All versions are pinned and tested together. Do not upgrade individual components without validating compatibility.

| Component | Version | Notes |
|---|---|---|
| Kubernetes | v1.34.x | kubelet, kubeadm, kubectl |
| Cilium CNI | v1.16.5 | AWS ENI IPAM mode, Hubble enabled |
| Containerd | v2.0.x | systemd cgroup driver |
| Ubuntu | 24.04 LTS | ARM64 (Graviton) |
| Helm | v3.16.4 | Pre-baked in Golden AMI |
| Cilium CLI | v0.18.3 | SHA256-verified install |
| OpenEBS | latest stable | Local PV provisioner |
| AWS NTH | latest stable | Spot termination handler |
| Packer | latest | AMI builder |
| Terraform AWS Provider | v5.0+ | |

---

## Prerequisites

Ensure the following tools are installed and configured on your local machine before deploying.

| Tool | Purpose | Install Guide |
|---|---|---|
| AWS CLI v2 | AWS authentication and resource access | [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| Terraform >= 1.5 | Infrastructure provisioning | [Install Terraform](https://developer.hashicorp.com/terraform/install) |
| Packer >= 1.10 | Golden AMI builder | [Install Packer](https://developer.hashicorp.com/packer/install) |
| kubectl | Cluster management | [Install kubectl](https://kubernetes.io/docs/tasks/tools/) |

**AWS IAM requirements:**

Your AWS credentials must have permissions to:
- Create and manage EC2 instances, AMIs, security groups, key pairs
- Manage VPC, subnets, route tables, NAT gateways, internet gateways
- Create and attach IAM roles and instance profiles
- Manage Auto Scaling Groups and Launch Templates

**SSH key:**

The deployment expects an Ed25519 public key at `~/.ssh/id_ed25519.pub`. If you use a different path, update `variables.tf`.

```bash
# Generate if you don't have one
ssh-keygen -t ed25519 -C "your-email@example.com"
```

---

## Quick Start

```bash
# 1. Clone the repository
git clone <repo-url>
cd terraform-aws-k8s-ha

# 2. Build the Golden AMI (one-time, or when updating baked dependencies)
cd packer
packer init .
packer build k8s-golden-ami.pkr.hcl
cd ..

# 3. Initialize Terraform
terraform init

# 4. Deploy (choose dev or prod)
terraform apply -var-file=dev.tfvars    # Development / cost-optimized
terraform apply -var-file=prod.tfvars   # Production / full-scale

# 5. Fetch kubeconfig
./fetch_kubeconfig.sh
export KUBECONFIG=$(pwd)/kubeconfig

# 6. Verify cluster
kubectl get nodes -o wide
kubectl get pods -A
```

---

## Deployment Guide

### Step 1 — Build the Golden AMI

The Golden AMI pre-installs all heavy dependencies (`containerd`, `kubeadm`, `kubectl`, `helm`, `cilium-cli`, kernel modules, sysctl tuning) so that EC2 instances only need lightweight runtime configuration at boot. This reduces node join time significantly.

```bash
cd packer
packer init .
packer build k8s-golden-ami.pkr.hcl
```

The AMI is tagged `k8s-ubuntu-2404-arm64-golden-v2-*` and is automatically discovered by Terraform via a data source. **Rebuild the AMI whenever you update baked component versions.**

### Step 2 — Configure Environment

Two environment configurations are provided:

**`dev.tfvars`** — Development/testing, cost-optimized:
```hcl
cluster_name                 = "k8s-dev-cluster"
master_instance_type         = "c7g.2xlarge"
gp_worker_instance_type      = "c6gd.4xlarge"
spark_critical_instance_type = "c6gd.4xlarge"
minio_instance_type          = "is4gen.xlarge"
worker_count                 = 1
worker_min                   = 1
worker_max                   = 2
spot_overrides               = ["c6gd.4xlarge", "m6gd.4xlarge", "c7gd.4xlarge"]
```

**`prod.tfvars`** — Production, full-scale:
```hcl
cluster_name                 = "k8s-ha-cluster"
master_instance_type         = "c7g.2xlarge"
gp_worker_instance_type      = "im4gn.4xlarge"
spark_critical_instance_type = "i4g.8xlarge"
minio_instance_type          = "im4gn.8xlarge"
worker_count                 = 3
worker_min                   = 3
worker_max                   = 4
spot_overrides               = ["r6gd.12xlarge", "i4g.8xlarge"]
```

### Step 3 — Provision Infrastructure

```bash
# Initialize providers and modules
terraform init

# Preview changes
terraform plan -var-file=prod.tfvars

# Apply
terraform apply -var-file=prod.tfvars
```

Terraform will:
1. Create VPC, subnets, route tables, NAT gateway
2. Create security groups, IAM roles, and SSH key pair
3. Launch the master EC2 instance — it bootstraps the control plane via user data
4. Launch worker Auto Scaling Groups — nodes automatically join the cluster

Bootstrap typically takes 3–6 minutes for the master and an additional 1–2 minutes for workers.

### Step 4 — Access the Cluster

```bash
# Automated kubeconfig retrieval
./fetch_kubeconfig.sh

export KUBECONFIG=$(pwd)/kubeconfig

# Verify
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

### Step 5 — Destroy

```bash
terraform destroy -var-file=dev.tfvars
```

> Always destroy dev environments when not in use to avoid unnecessary AWS costs.

---

## Repository Structure

```
terraform-aws-k8s-ha/
├── packer/
│   ├── k8s-golden-ami.pkr.hcl    # Packer build definition (Ubuntu 24.04 ARM64)
│   ├── common-ami.sh              # AMI bootstrap: packages, kernel, containerd, K8s binaries
│   └── build.sh                   # Convenience wrapper for packer build
│
├── scripts/
│   ├── common-runtime.sh          # Runs on ALL nodes: swap, NVMe RAID, Cilium route fix, sysctl
│   ├── master-runtime.sh          # Master only: kubeadm init, Cilium, OpenEBS, NTH install
│   ├── common.sh                  # Shared utility functions
│   ├── verify-setup.sh            # Post-deploy validation checks
│   └── README.md                  # Scripts-specific documentation
│
├── # Terraform — Core
├── providers.tf                   # AWS provider configuration
├── variables.tf                   # All input variables with defaults
├── data.tf                        # AMI data sources (golden + upstream Ubuntu)
├── network.tf                     # VPC, subnets, IGW, NAT, route tables
├── security.tf                    # Security groups for master and workers
├── iam.tf                         # IAM roles and ENI management policies
├── outputs.tf                     # Cluster outputs (master IP, etc.)
│
├── # Terraform — Compute
├── compute-master.tf              # Control plane EC2 instance
├── compute-k8s-gp.tf              # General-purpose worker ASG
├── compute-spark-critical.tf      # Dedicated Spark nodes
├── compute-spark-spot.tf          # Spot fleet for Spark workloads
├── compute-minio.tf               # MinIO storage nodes
│
├── # Environment Configs
├── dev.tfvars                     # Development: small instances, single worker
├── prod.tfvars                    # Production: full-size instances, HA workers
│
├── # Utilities
├── deploy.sh                      # Interactive deploy/destroy menu
├── fetch_kubeconfig.sh            # Retrieves kubeconfig from master
├── get_prices.py                  # AWS instance pricing lookup
├── update_compute.py              # Compute configuration update helper
│
├── # Documentation
├── README.md                      # This file
├── CHANGELOG.md                   # Version history
├── RELEASE.md                     # Release notes
└── issues.md                      # Technical troubleshooting log
```

---

## Node Roles

Nodes are automatically labeled at boot via a systemd service. Labels are applied based on the EC2 instance naming convention set at launch.

| Role | Label | Instance Types | Purpose |
|---|---|---|---|
| Master | `node-role.kubernetes.io/master` | c7g.2xlarge | Control plane, etcd |
| GP Worker | `role=gp-worker` | im4gn.4xlarge | General workloads |
| Spark Critical | `role=spark-critical` | i4g.8xlarge | Dedicated Spark compute |
| Spark Spot | `role=spark-spot` | r6gd.12xlarge (+ overrides) | Cost-optimized Spark |
| MinIO | `role=minio` | im4gn.8xlarge | Object storage |

Use node selectors or affinity rules in your workload manifests to target specific node pools:

```yaml
nodeSelector:
  role: spark-critical
```

---

## Networking

### Cilium CNI (AWS ENI IPAM)

Cilium runs in AWS ENI IPAM mode, assigning each pod a real secondary private IP from the pod subnet (`10.0.4.0/24`). This provides:
- Native VPC routing for pods (no overlay overhead)
- Network policy enforcement via eBPF
- Hubble observability for flow-level visibility

**Critical workaround applied** — A kernel routing fix (`ip route replace local`) is applied in `common-runtime.sh` before Cilium starts. Without this, Cilium's ENI IPAM hijacks the local routing table and causes `etcd` and `kube-apiserver` to crash-loop on the master. See `issues.md` for full root cause analysis.

### MetalLB (Layer 2)

MetalLB is installed for LoadBalancer service support in environments where AWS ELB integration is not used. It operates in Layer 2 mode, advertising service IPs via ARP within the VPC.

### AWS Node Termination Handler

The AWS Node Termination Handler (NTH) is deployed as a DaemonSet. It intercepts EC2 Spot interruption notices and automatically cordons and drains the affected node before termination, allowing graceful pod rescheduling.

---

## Storage

### NVMe Auto-Detection and RAID 0

`common-runtime.sh` runs on every node at boot and automatically handles local NVMe instance store disks:

| Disk Count | Action |
|---|---|
| 0 | No action (EBS-only node) |
| 1 | Format as XFS, mount to `/mnt/spark-nvme` |
| 2+ | Create RAID 0 array (mdadm), format as XFS, mount to `/mnt/spark-nvme` |

Mount is persisted in `/etc/fstab` for automatic remount on reboot. This path is used by OpenEBS `hostpath` volumes and Spark local scratch directories.

### OpenEBS Local Provisioner

OpenEBS is installed on the master as a Helm chart. It creates a `StorageClass` backed by the local NVMe path, enabling dynamic `PersistentVolumeClaim` provisioning for stateful workloads.

### Dedicated etcd EBS Volume

The master node has a secondary 10GB `gp3` EBS volume mounted at `/var/lib/etcd`. This isolates etcd I/O from the OS root volume, preventing I/O starvation during heavy cluster operations.

---

## Golden AMI Pipeline

The Packer-based Golden AMI pipeline produces a reusable, pre-baked AMI that dramatically reduces node boot time. All software installation happens at AMI build time, not at instance launch.

**What is baked into the AMI:**

| Layer | Details |
|---|---|
| Base OS | Ubuntu 24.04 LTS ARM64 |
| Kernel | Pinned to `6.8.0-1021-aws` (prevents unattended upgrades) |
| Kernel modules | `overlay`, `br_netfilter` (loaded + persisted via `/etc/modules-load.d`) |
| Sysctl tuning | K8s networking, high file descriptor limits, BBR congestion control, `rp_filter=0` for Cilium |
| Packages | `jq`, `curl`, `nvme-cli`, `mdadm`, `xfsprogs`, `iproute2`, `awscli v2` |
| Containerd | Latest v2.x pinned at build time, systemd cgroup enabled |
| Kubernetes | `kubelet`, `kubeadm`, `kubectl` v1.34.4, held via `apt-mark hold` |
| Helm | v3.16.4 |
| Cilium CLI | v0.18.3 (SHA256-verified) |
| Crictl | v1.34.0 |

**Rebuild the AMI when:**
- Upgrading Kubernetes, Cilium, or Containerd versions
- Applying OS-level patches
- Modifying kernel parameters or sysctl tuning

```bash
cd packer
packer build k8s-golden-ami.pkr.hcl
# Then re-apply Terraform to roll new AMI to nodes
terraform apply -var-file=prod.tfvars
```

---

## Security

### Network Boundaries

| Resource | Access |
|---|---|
| Master SSH (22) | Public internet (restrict to your IP in `security.tf` for production) |
| Kubernetes API (6443) | Public internet (restrict to your IP for production) |
| Worker SSH (22) | Master node and VPC CIDR only |
| Worker kubelet (10250) | Master node only |
| Inter-node (all) | Within VPC security group |
| Pod subnet traffic | Both master and worker security groups |

> **Recommendation:** In production, restrict SSH and API access to specific CIDR ranges in `security.tf` rather than `0.0.0.0/0`.

### IAM Least Privilege

Worker and master nodes operate under a dedicated IAM role (`k8s-node-role`) with only the permissions required for Cilium ENI management:
- Describe VPC resources (subnets, security groups, instance types)
- Create, attach, detach, and delete ENIs
- Assign and unassign secondary private IPs
- Terminate self (used by worker nodes on failed cluster join)

### IMDSv2 Enforced

The Packer build enforces IMDSv2 on the builder instance. All EC2 instances launched from the resulting AMI inherit this posture, preventing SSRF-based metadata access attacks.

---

## Scaling

### Horizontal Scaling (Workers)

Update the ASG parameters in `variables.tf` or the relevant `compute-*.tf` file, then re-apply Terraform:

```hcl
# variables.tf
variable "worker_min" { default = 3 }
variable "worker_max" { default = 8 }
```

```bash
terraform apply -var-file=prod.tfvars
```

New nodes will automatically join the cluster using the kubeadm bootstrap token.

### Spot Instance Fleet

The Spark Spot node group uses a mixed instances policy with configurable overrides:

```hcl
# prod.tfvars
spot_overrides = ["r6gd.12xlarge", "i4g.8xlarge"]
```

Spot interruptions are handled gracefully by AWS Node Termination Handler.

---

## Troubleshooting

Common issues and their resolutions are documented in detail in [issues.md](issues.md).

### Cluster API Unreachable

If `kubectl` cannot reach the cluster after deploy, verify:
1. The master node's user data has completed: `ssh ubuntu@<master-ip> "sudo cloud-init status"`
2. The API server is running: `ssh ubuntu@<master-ip> "sudo kubectl get pods -n kube-system"`
3. Security group rule for port 6443 allows your source IP

### Nodes Not Joining

Worker nodes retry kubeadm join up to 3 times before self-terminating. Check:
1. The bootstrap token hasn't expired (default TTL: 24h)
2. The master API is reachable from the private subnet
3. Worker user data logs: `ssh ubuntu@<master-ip>` then `ssh <worker-ip>` → `sudo journalctl -u cloud-final`

### Cilium Pods CrashLooping

This is typically the ENI IPAM routing conflict. Verify `common-runtime.sh` ran successfully:
```bash
ssh ubuntu@<master-ip> "sudo journalctl -u cloud-final | grep 'ip route'"
```
See `issues.md` for the full root cause and fix.

### NVMe Not Detected

If `/mnt/spark-nvme` is missing on a node, the NVMe detection in `common-runtime.sh` may have failed. Check:
```bash
lsblk                          # Are disks visible?
sudo journalctl -u cloud-final # Did the script error?
```

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-change`
3. Test changes in the dev environment first: `terraform apply -var-file=dev.tfvars`
4. Update documentation if introducing new components or changing behavior
5. Submit a pull request with a clear description of the change and its motivation

---

## License

This project is provided as-is for infrastructure automation purposes. Review all scripts and Terraform configurations before deploying to your environment.
