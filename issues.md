# Project Issues & Resolutions

This document tracks the critical technical hurdles encountered during the evolution of this Kubernetes HA cluster and the specialized fixes applied to resolve them.

## 1. Kubernetes 1.34 & Containerd 2.0 Compatibility
**Issue**: Standard `containerd.io` installations often default to `v1.x`, which lacks certain features or optimizations required for stable Kubernetes `v1.34.x` operation on ARM64.
**Resolution**: Modified the Golden AMI build script (`common-ami.sh`) to dynamically fetch and pin the latest `2.0.x` version of `containerd.io` from the official Docker repository.
- **Fix**: Used `apt-cache madison containerd.io | grep -E '^2\.'` to identify and install the major version 2.

## 2. MetalLB Controller CrashLoopBackOff (Cilium Conflict)
**Issue**: The MetalLB controller would crash immediately upon boot. This was caused by a conflict with Cilium’s strict ARP handling and the default Pod Security Standards (PSS) in K8s 1.34.
**Resolution**: 
- Configured Cilium with `kubeProxyReplacement=true` and `l2announcements.enabled=true`.
- Disabled the MetalLB `frr` BGP container (`--set speaker.frr.enabled=false`) as it was attempting to bind to privileged host ports/sockets that Cilium already claimed or blocked.

## 3. MetalLB Speaker stuck in `Init:0/3`
**Issue**: Speakers were failing to initialize because they couldn't schedule on the Control Plane (due to taints) or were blocked by network readiness checks.
**Resolution**: 
- Added `--set speaker.tolerateMaster=true` to allow the speaker daemonset to run on the master node.
- Applied explicit `nodeSelectors` to ensure the controller and speakers mapped correctly to their architectural targets.

## 4. Master Node Initialization Timeout
**Issue**: The `master-runtime.sh` script (invoked via AWS User Data) was terminating prematurely. 
**Root Cause**: The command `cilium status --wait` had a 60-second timeout. On ARM64 instances, the initial pod pull and start sometimes exceeded this window. When the command timed out and returned a non-zero exit code, the `set -e` in the bash script caused the entire initialization to stop, skipping the MetalLB and OpenEBS installations.
**Resolution**: Removed `cilium status --wait` and replaced it with a simple `sleep 30`. This allows the script to proceed to the next Helm charts while Kubernetes handles the eventual consistency of the pod states.

## 5. Storage Class Failures (OpenEBS)
**Issue**: Pods requiring persistent storage remained in `Pending` because no `StorageClass` was present or the default was not set correctly.
**Resolution**: Integrated `openebs` installation into the `master-runtime.sh` script with the `localprovisioner` enabled. This provides a `openebs-hostpath` storage class that utilizes the high-performance local NVMe storage we configured.

## 6. Etcd I/O Starvation During First-Time Bootstrap
**Issue**: On first-time cluster deployment, applying CRDs and the full K8s stack simultaneously triggers massive Docker image pulls that saturate the root EBS volume's I/O bandwidth. Since etcd shared the same root disk, its WAL writes and snapshot operations were starved, causing etcd to hang and the entire control plane to become unresponsive.
**Resolution**: Multi-pronged fix:
- **Dedicated EBS for etcd**: Added a 2GB gp3 EBS volume (`/dev/xvdf`) mounted at `/var/lib/etcd`, physically isolating etcd I/O from image pulls and other root disk activity.
- **Etcd tuning**: Configured cloud-friendly heartbeat interval (500ms), election timeout (5s), auto-compaction (1h), and reduced snapshot frequency (`snapshot-count: 5000`) via kubeadm `ClusterConfiguration` to reduce etcd's own I/O pressure.
- **Kubelet resource reservations**: Added `system-reserved=cpu=500m,memory=512Mi` and `kube-reserved=cpu=500m,memory=512Mi` to prevent pods from starving system daemons.
- **Serialized Helm installs**: Added 30s sleep between NTH and OpenEBS Helm chart installations to avoid concurrent image pull I/O storms.

## 7. Control Plane Deadlock (Cilium AWS ENI IPAM)
**Issue**: Cilium AWS ENI IPAM assigned secondary IPs to the primary master ENI (e.g., `ens5`). The Linux kernel arbitrarily chose a secondary pod IP (e.g., `10.0.1.109`) as the source IP for local traffic to the master's primary IP (`10.0.1.188`). Traffic from the pod IP hit Cilium's policy routing tables and was dropped, effectively blackholing `localhost -> 10.0.1.188` traffic. This caused `etcd` to time out and the Kubernetes API server to crash-loop.
**Resolution**: Forced the local routing table to use the primary IP as the source. Appended a permanent `ip route replace local <primary-ip> dev <device> table local proto kernel scope host src <primary-ip>` rule to the `common-runtime.sh` boot script so all traffic inherently uses the correct source IP before Cilium is ever installed.

## 8. AWS Spot Fleet UnfulfillableCapacity Errors
**Issue**: Spot instances in the `k8s-dev-cluster-workers-asg` Auto Scaling Group were failing to launch with `UnfulfillableCapacity` errors. This happens when the specified availability zone (`us-east-1a`) runs out of spot capacity for the requested instance types (e.g., `c6gd.4xlarge`).
**Resolution**: Broadened the `spot_overrides` configuration in `dev.tfvars` to include a wider range of equivalent 4xlarge instances across different Graviton generations (`c6g`, `m6g`, `c7g`, `m7g`, `r6g`), significantly increasing the pool of available spot capacity. The general-purpose and spark-critical nodes were also adjusted to non-NVMe instance types (`c6g.2xlarge` and `c6g.4xlarge`) to mitigate potential constraints when scaling them.

## 9. Kubeadm Init Hangs on NVMe EBS Mapping and v1beta4 Config
**Issue**: The control plane node was failing to initialize and hanging near the end of cloud-init execution.
**Root Causes**: 
1. **NVMe Symlink Bug**: The `user_data` script attempted to find the dedicated etcd EBS volume by reading symlinks in `/dev/disk/by-id/*xvdf*`. However, AWS Nitro no longer maps the EBS device name (`/dev/xvdf`) to a predictable symlink on newer AMIs, causing `readlink` to fail or match literal wildcards, breaking the etcd mount logic.
2. **Kubeadm v1beta4 Syntax**: Kubeadm `v1beta4` requires the `LocalEtcd.etcd.local.extraArgs` configuration to be an array of `name`/`value` dictionaries rather than a flat key-value map.
3. **Preflight Checks**: Since the etcd dir was formatted and mounted explicitly *before* `kubeadm init`, kubeadm failed its preflight check (`DirAvailable--var-lib-etcd` because the dir was not empty).
**Resolution**:
- Removed the problematic `readlink` logic and relied solely on the robust fallback size-and-mount checking algorithm to identify the 2GB etcd volume.
- Migrated the `extraArgs` syntax in `master-runtime.sh` to the required array format for `v1beta4`.
## 10. Control Plane Instability & BPF Verifier Crash (ARM64)
**Issue**: Even with a dedicated etcd EBS volume, the API server became unresponsive, with etcd rejecting connections (`TLS handshake failed: EOF`) and `kubectl` commands timing out.
**Root Cause**: A critical kernel-level **BPF verifier bug** (`REG INVARIANTS VIOLATION`) was triggered on the master node (c7g / ARM64). This crash occurred when Cilium attempted to load eBPF programs into the kernel. The resulting kernel instability corrupted the networking stack, causing local loopback communication to `etcd` (127.0.0.1:2379) to fail or be blocked.
**Resolution**:
- **Webhook Removal**: Temporarily deleted the `spark-operator` and `kube-prometheus-stack` admission webhooks to prevent they from blocking API server startup during the network instability.
- **Service Suspension**: Stopped the `cilium-agent` container on the master node to stop further BPF load attempts that were crashing the kernel.
- **Master Reboot**: Rebooted the master node to clear the corrupted kernel/BPF state and restore stable networking for core control plane services (etcd, apiserver).
- **Stable Version**: Downgrading Cilium to a more stable version (`v1.18.6`) for the ARM64 environment and monitoring for kernel-level stability.

## 11. Persistent BPF Compilation Failures (ARM64)
**Issue**: Even with a stable Cilium version (`v1.18.6`), the Cilium agent on ARM64 nodes consistently fails to compile BPF programs for pods.
**Root Cause**: The error `failed to compile template program: Failed to compile bpf_lxc.o: exit status 1` indicates that the BPF compilation toolchain (clang/llc) inside the Cilium container is hitting an architectural or kernel-header mismatch. This prevents pods from reaching each other or the API server, leading to probe timeouts (`context deadline exceeded`).
**Resolution**: Currently investigating a further Cilium version shift or manually injecting compatible kernel-headers.

## 12. Network Interface Proliferation (Host ENI Leak)
**Issue**: A second network interface (`ens6`) unexpectedly appears on the master node, sharing the same subnet (`10.0.1.0/24`) as the primary interface (`ens5`).
**Root Cause**: This creates a dual-default-route scenario. When services try to connect via the private IP `10.0.1.61`, the kernel often attempts to route responses through the secondary interface, leading to asymmetric routing and connection timeouts. This is likely due to the `aws-node-termination-handler` or another AWS-integrated component misidentifying the node's network needs and attaching a second ENI.
**Resolution**: Restored connectivity by manually disabling `ens6` and clearing Cilium's persistent BPF maps to force standard kernel routing.

## 13. Stale Ingress Domain Propagation (Kustomize Vars)
**Issue**: Re-applying manifests does not update Ingress hostnames (e.g., `airflow.44.203.26.241.sslip.io`). They remain stuck on the old master IP despite updates to `global-config.env`.
**Root Cause**: Kustomize `vars` substitution for `INGRESS_DOMAIN` is failing because the `global-config` ConfigMap is generated with a hash suffix (e.g., `global-config-htckf6b7bm`), but the `vars` definition in the root `kustomization.yaml` references the base name. Additionally, the substitution may not be reaching nested `04-configs/ingress.yaml` correctly.
**Resolution**: Plan to use Kustomize `replacements` (the non-deprecated alternative to `vars`) and ensure the ConfigMap hash is correctly handled or disabled for configuration constants.
