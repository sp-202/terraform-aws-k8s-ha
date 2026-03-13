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

## 10. Persistent BPF Compilation Failures (ARM64)
**Issue**: Even with a stable Cilium version (`v1.18.6`), the Cilium agent on ARM64 nodes consistently fails to compile BPF programs for pods.
**Root Cause**: The error `failed to compile template program: Failed to compile bpf_lxc.o: exit status 1` indicates that the BPF compilation toolchain (clang/llc) inside the Cilium container is hitting an architectural or kernel-header mismatch on kernel `6.17.0-1007-aws` (too new for Cilium 1.16.5 BPF on ARM64). Additionally, `kubeProxyReplacement=true` triggered a `REG INVARIANTS VIOLATION` BPF verifier crash on Graviton3 (c7g) instances.
**Root Cause**: 
- Cilium `v1.18.6` was too new and unstable on ARM64 Graviton
- Kernel `6.17.0-1007-aws` (Ubuntu 24.04 default) incompatible with Cilium 1.16.5 BPF toolchain
- `kubeProxyReplacement=true` caused BPF verifier crash on Graviton3
**Resolution**: 
- Downgraded Cilium to `v1.16.5` (stable ARM64 BPF toolchain)
- Pinned kernel to `6.8.0-1021-aws` in Golden AMI via `apt-mark hold` and GRUB default override
- Set `kubeProxyReplacement=false` to avoid BPF verifier crash
- Removed unattended-upgrades to prevent kernel drift
- New Golden AMI (`k8s-ubuntu-2404-arm64-golden-v2`) built and validated — all 5 nodes now running `6.8.0-1021-aws` with Cilium 5/5 healthy

---

## 11. Network Interface Proliferation (Host ENI Leak)
**Issue**: A second network interface (`ens6`) unexpectedly appears on the master node, sharing the same subnet (`10.0.1.0/24`) as the primary interface (`ens5`). Additionally stale `CiliumNode` objects remained after instance termination.
**Root Cause**: 
- Master node was untainted (`kubectl taint nodes --all node-role.kubernetes.io/control-plane-`), allowing Cilium ENI IPAM to allocate a pod ENI on the master — this is the `ens6` leak
- Cilium ENI mode allocates real AWS ENIs per node for pod IPs; without the exclusion annotation, master gets one too
- Wrong Helm key `eni.nodeSpec.subnetTags[0]` prevented correct subnet tagging
- kube-proxy deleted before Cilium was healthy caused a networking gap
**Resolution**: 
- Replaced `kubectl taint nodes --all` with master ENI exclusion annotation:
```bash
  kubectl annotate node <master> "io.cilium.aws/exclude-from-eni-allocation=true"
```
- Fixed Cilium install Helm key to `eni.subnetTags.cilium-pod-subnet=1`
- Added `cilium status --wait --timeout=180s` gate before deleting kube-proxy
- Added `bpf.preallocateMaps=false` and `eni.updateEC2AdapterLimitViaAPI=true`
- Added `rp_filter=0` sysctl in Golden AMI for Cilium ENI native routing
- Verified: CiliumNode count matches Node count exactly (diff returns empty), no leaked ENIs in AWS

---

## 12. Golden AMI Build Failures (Packer)
**Issue**: Packer AMI build failing with `E: Unable to locate package ebsnvme-id` and `sha256sum: cilium-linux-arm64.tar.gz: No such file or directory`.
**Root Cause**:
- `ebsnvme-id` is an Amazon Linux package — does not exist in Ubuntu apt repos
- Cilium CLI downloaded as `cilium-cli.tar.gz` but sha256sum manifest references original filename `cilium-linux-arm64.tar.gz` — name mismatch caused checksum failure
- `DEBIAN_FRONTEND` not set causing debconf dialog warnings throughout build
- GRUB not explicitly set to boot pinned kernel — newer kernel (`6.17.x`) would boot instead of pinned `6.8.0-1021-aws`
**Resolution**:
- Removed `ebsnvme-id` from apt install list (nvme-cli is the correct Ubuntu package)
- Fixed Cilium download to use original filename matching sha256sum manifest:
```bash
  curl ... -o "cilium-linux-${CLI_ARCH}.tar.gz"
  sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
```
- Added `export DEBIAN_FRONTEND=noninteractive` at top of `common-ami.sh`
- Added GRUB default override to pin boot kernel:
```bash
  sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="Advanced options..."/' /etc/default/grub
  sudo update-grub
```
- AMI `k8s-ubuntu-2404-arm64-golden-v2` successfully built and validated