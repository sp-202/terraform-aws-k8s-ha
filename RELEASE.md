# Release Notes

---

## v1.0.0 — 2026-03-18

**Initial stable release of `terraform-aws-k8s-ha`**

This release marks the first production-ready version of the automated Kubernetes 1.34 HA cluster deployment on AWS Graviton (ARM64). It incorporates all foundational infrastructure, a fully automated bootstrap pipeline, battle-tested fixes for Cilium ENI IPAM stability, and environment-aware configuration for both dev and production deployments.

---

### Highlights

- Full Kubernetes 1.34 cluster deployment via a single `terraform apply`
- Golden AMI pipeline (Packer) reduces node bootstrap time to under 2 minutes
- Cilium 1.16.5 with AWS ENI IPAM and Hubble observability
- Automatic NVMe discovery and RAID 0 setup at boot
- Separate `dev.tfvars` / `prod.tfvars` for cost-aware environment targeting
- Critical fix for Cilium ENI IPAM / etcd crash-loop resolved and hardened

---

### What's Included

#### Infrastructure (Terraform)

- **VPC architecture**: Public subnet for master, private subnet for workers, dedicated pod subnet (`10.0.4.0/24`) for Cilium ENI IPAM secondary IPs
- **Master node** (`c7g.2xlarge`): Single control plane EC2 with dedicated 10GB `gp3` EBS for etcd I/O isolation
- **General-purpose worker ASG** (`im4gn.4xlarge`): Auto Scaling Group with automatic cluster join on launch
- **Spark Critical node group** (`i4g.8xlarge`): Dedicated high-IOPS nodes for Spark compute workloads
- **Spark Spot fleet**: Mixed instances policy with configurable instance type overrides for cost-optimized Spark jobs
- **MinIO node group** (`im4gn.8xlarge`): NVMe-optimized nodes for S3-compatible object storage
- **IAM least-privilege role**: Covers only Cilium ENI management permissions required by the CNI plugin
- **Security groups**: Strict ingress/egress rules scoped to master, workers, pod subnet, and VPC

#### Golden AMI (Packer)

- Base: Ubuntu 24.04 LTS ARM64 (Canonical `099720109477`)
- Kernel pinned to `6.8.0-1021-aws` — prevents unattended-upgrades from introducing untested kernels
- Pre-baked: `containerd v2.0.x`, `kubelet/kubeadm/kubectl v1.34.4`, `helm v3.16.4`, `cilium-cli v0.18.3`, `crictl v1.34.0`
- Kernel modules `overlay` and `br_netfilter` loaded and persisted
- Full sysctl tuning: K8s networking, high file descriptor limits, BBR congestion control, `rp_filter=0` for Cilium
- IMDSv2 enforced on builder instance
- All binaries SHA256-verified where applicable

#### Runtime Scripts

- **`common-runtime.sh`**: Runs on all nodes. Handles swap disable, kubelet configuration, Cilium ENI route fix, NVMe RAID 0 auto-setup, and cgroup v2 validation
- **`master-runtime.sh`**: Runs on master only. Executes `kubeadm init`, installs Cilium (Helm), installs OpenEBS, installs AWS Node Termination Handler, configures auto-node-labeling systemd service, and sets up kubeconfig for the `ubuntu` user
- **`verify-setup.sh`**: Post-deployment validation for node readiness, CNI health, and storage mounts

#### Networking

- Cilium CNI v1.16.5 in AWS ENI IPAM mode with Hubble enabled
- MetalLB for Layer 2 LoadBalancer support
- AWS Node Termination Handler for graceful Spot draining

#### Storage

- Automatic NVMe instance store detection and RAID 0 (mdadm) setup at `/mnt/spark-nvme`
- OpenEBS local provisioner using NVMe path as storage backend
- Persistent `/etc/fstab` entries for NVMe mounts

#### Developer Tooling

- `deploy.sh`: Interactive menu for deploy/destroy across dev and prod
- `fetch_kubeconfig.sh`: Automated kubeconfig retrieval from master
- `get_prices.py`: AWS instance pricing lookup utility
- `update_compute.py`: Compute configuration helper

---

### Bug Fixes

#### Critical: Cilium ENI IPAM Causes etcd / kube-apiserver Crash-Loop

**Severity:** Critical
**Affected component:** `common-runtime.sh`, all nodes
**Root cause:** Cilium in AWS ENI IPAM mode attaches secondary private IPs to the instance's network interface. The Linux kernel's local routing table treats these secondary IPs as local addresses. When `kubelet` or `etcd` binds to the primary private IP, outgoing packets sourced from secondary IPs are misrouted through the `local` table, causing connection failures between control plane components.
**Fix:** Added `ip route replace local <primary-ip> dev eth0 table local` in `common-runtime.sh`, executed before Cilium starts. This explicitly anchors the primary IP in the local table and prevents secondary ENI IPs from overriding it.
**References:** `issues.md` — Issue #3 (Cluster API Unreachable via ClusterIP)

#### Fixed: ASG Validation Rejects Single-Node Dev Deployments

**Severity:** Low
**Affected component:** `variables.tf`
**Root cause:** Strict validation rules on ASG `min_size` and `max_size` variables enforced a minimum of 2 workers, making single-node dev deployments fail at plan time.
**Fix:** Relaxed validation to allow `min_size = 1` for testing and dev environments.

---

### Known Limitations

- The master node has a single public IP and is a single point of failure for the control plane. Multi-master HA (stacked etcd) is not implemented in this release.
- SSH and Kubernetes API (6443) are open to `0.0.0.0/0` by default in `security.tf`. Restrict to known CIDR ranges before deploying to production.
- Bootstrap tokens used for worker join have a 24-hour TTL. Nodes launched after token expiry will fail to join and self-terminate. Regenerate tokens if deploying in batches over multiple days.
- The `dns.tf` and `main-code-server.tf` configurations are disabled and not tested in this release.

---

### Upgrade Notes

This is the initial release. No migration steps are required.

For future upgrades:
1. Rebuild the Golden AMI after changing any baked component version
2. Run `terraform plan` before `apply` to review instance replacement impact
3. Drain and cordon nodes manually before rolling instance type changes in production

---

### Tested Configurations

| Environment | Master | GP Workers | Spark | MinIO | Spot Fleet |
|---|---|---|---|---|---|
| Dev | c7g.2xlarge | c6gd.4xlarge x1 | c6gd.4xlarge | is4gen.xlarge | c6gd / m6gd / c7gd |
| Prod | c7g.2xlarge | im4gn.4xlarge x3 | i4g.8xlarge | im4gn.8xlarge | r6gd.12xlarge / i4g.8xlarge |

AWS Region: `us-east-1` (primary tested region)

---

### Contributors

- Infrastructure design and implementation
- Cilium ENI IPAM debugging and fix
- NVMe RAID auto-detection logic
- Golden AMI pipeline
- Environment parameterization (dev/prod tfvars)

---

*For a detailed history of changes, see [CHANGELOG.md](CHANGELOG.md).*
*For resolved technical issues and their root cause analysis, see [issues.md](issues.md).*
