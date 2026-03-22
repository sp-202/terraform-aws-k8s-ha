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

## 13. Cilium ENI Mode Allocating Pod IPs from Node Subnet

**Issue**: All pods receiving IPs from node subnets (`10.0.1.x`, `10.0.2.x`) instead of dedicated pod subnet (`10.0.4.x`). Control plane crashing with `kube-apiserver` CrashLoopBackOff, `etcd` gRPC handshake failures, and Traefik unable to reach `10.96.0.1:443`.

**Root Cause**:
- `POD_CIDR="10.0.0.0/8"` overlapped entire VPC including node IPs — Cilium eBPF intercepted loopback/node traffic causing `etcd` and `kube-apiserver` communication failure
- `kubeProxyReplacement=false` with ENI mode is contradictory — neither Cilium nor kube-proxy fully owned service routing, making `10.96.0.1` unreachable
- kube-proxy deleted **after** Cilium install instead of before — caused iptables/eBPF rule conflicts during the overlap window
- `cilium install` CLI silently drops ENI operator flags — `--subnet-tags-filter` and `--subnet-ids-filter` showed empty in operator logs despite being passed
- Wrong Helm key used: `eni.subnetIDs` maps to per-node `nodeSpec` config, NOT the global operator filter. Correct key is `eni.subnetIDsFilter`
- Pod subnet CIDR mismatch: Terraform created `10.0.4.0/24` but script had `10.0.4.0/23`
- Subnet ID hardcoded in script — breaks on every `terraform destroy` + `apply` cycle

**Resolution**:
- Fixed `POD_CIDR` to match dedicated pod subnet only:
```bash
POD_CIDR="__POD_CIDR__"   # injected dynamically by Terraform
```
- Switched to `kubeProxyReplacement=true` and added required apiserver flags:
```bash
--set kubeProxyReplacement=true \
--set k8sServiceHost="$MASTER_PRIVATE_IP" \
--set k8sServicePort=6443
```
- Moved kube-proxy deletion to **before** Cilium install:
```bash
kubectl -n kube-system delete daemonset kube-proxy 2>/dev/null || true
kubectl -n kube-system delete configmap kube-proxy 2>/dev/null || true
```
- Switched from `cilium install` CLI to `helm install` for reliable ENI operator flag passing
- Used correct global subnet filter key:
```bash
--set eni.subnetIDsFilter[0]="__POD_SUBNET_ID__"
```
- Added dynamic Terraform injection in `compute-master.tf` user_data:
```bash
sed -i 's|__POD_CIDR__|${var.pod_subnet_cidr}|g' /root/master-runtime.sh
sed -i 's|__POD_SUBNET_ID__|${aws_subnet.pods.id}|g' /root/master-runtime.sh
```
- Also fixed EC2 `user_data` 16KB limit by moving scripts to S3 instead of base64-encoding inline
- Pods now correctly receive IPs from `10.0.4.x` pod subnet ✅

## 14. OpenEBS localpv-provisioner CrashLoopBackOff

**Issue**: `openebs-localpv-provisioner` and `openebs-ndm-operator` crashing with:
```
failure in preupgrade tasks: failed to list localpv based pv(s):
dial tcp 10.96.0.1:443: i/o timeout
```

**Root Cause**:
- Helm chart version `3.10.0` pulling container image `3.5.0` — version mismatch causes pre-upgrade API call to fail
- Pinning `--version` in helm install without also pinning image tags leads to inconsistent versions

**Resolution**:
- Removed version pin from `master-runtime.sh` helm install — let helm pull latest stable with consistent chart and image versions:
```bash
helm upgrade --install openebs openebs/openebs \
  --namespace openebs --create-namespace \
  --set localprovisioner.enabled=true
```

## 15. kubeadm init fails with "unknown flag: --skip-phase"

**Issue**: `kubeadm init` fails immediately with:
```
error: unknown flag: --skip-phase
```
Cluster never initializes. No kubeconfig, no API server, no kubelet configuration. All subsequent commands in master-runtime.sh silently fail.

**Root Cause**:
- Kubernetes 1.34 kubeadm uses `--skip-phases` (plural), not `--skip-phase` (singular)
- Single character difference causes total cluster failure with a non-obvious error message

**Resolution**:
- Changed `--skip-phase` to `--skip-phases` in `master-runtime.sh`:
```bash
sudo kubeadm init --config /tmp/kubeadm-config.yaml --skip-phases=addon/kube-proxy
```

---

## 16. API Server advertises 0.0.0.0 — ClusterIP 10.96.0.1 unreachable

**Issue**: Pods fail with:
```
dial tcp 10.96.0.1:443: i/o timeout
```
The `kubernetes` service endpoint resolves to `0.0.0.0:6443` instead of the master's real IP.

**Root Cause**:
- Terraform sets `PUBLIC_IP_ACCESS="true"` via sed, which made the script set `ADVERTISE_ADDRESS="0.0.0.0"`
- API server advertised `0.0.0.0`, so the kubernetes ClusterIP service endpoint became `0.0.0.0:6443` — not routable from inside pods

**Resolution**:
- Changed `ADVERTISE_ADDRESS` from `"0.0.0.0"` to `"$MASTER_PRIVATE_IP"` in the `PUBLIC_IP_ACCESS == "true"` block. Public IP remains in `certSANs` for external access:
```bash
ADVERTISE_ADDRESS="$MASTER_PRIVATE_IP"
CERT_SANS="$MASTER_PUBLIC_IP,$MASTER_PRIVATE_IP,127.0.0.1,localhost"
```

---

## 17. Asymmetric routing — pods on workers cannot reach API server on master

**Issue**: Pods on worker nodes timeout connecting to the API server via both ClusterIP (`10.96.0.1:443`) and direct IP (`10.0.1.x:6443`). Host-level `nc -nvz` works fine. Affects all in-cluster components: CoreDNS, Hubble, OpenEBS, application workloads.

**Root Cause**:
- Cilium ENI IPAM mode attaches a secondary ENI from the pod subnet (`10.0.4.0/24`) to the master node
- This creates a route `10.0.4.0/24 dev ens6` on the master
- When a pod on a worker sends a request to the API server at `10.0.1.x:6443`, the response packet is routed back via `ens6` (pod subnet) instead of `ens5` (public subnet) because `10.0.4.0/24` is a more specific match
- Response has wrong source IP/interface — dropped by the network stack (classic asymmetric routing)
- Cilium continuously re-creates the ENI even after manual route deletion (`ens6` → `ens7` → `ens8`)

**Resolution**:
Three-layer defense implemented in `master-runtime.sh`:

1. **Systemd watchdog** (`fix-master-eni.service`) — installed *before* Cilium, runs every 3 seconds, detects any pod-subnet ENI on the master, brings it down and flushes routes:
```bash
cat << 'FIXSCRIPT' > /usr/local/bin/fix-master-eni.sh
#!/bin/bash
while true; do
  for iface in $(ls /sys/class/net/ | grep -E '^ens[0-9]+$' | grep -v ens5); do
    if ip addr show "$iface" 2>/dev/null | grep -q '10\.0\.4\.'; then
      ip link set "$iface" down 2>/dev/null || true
      ip route flush dev "$iface" 2>/dev/null || true
    fi
  done
  sleep 3
done
FIXSCRIPT
```

2. **Cilium Helm flag** — tells operator to skip ENI allocation on control-plane nodes:
```bash
--set eni.excludeNodeLabelKey=node-role.kubernetes.io/control-plane
```

3. **Node annotation** — redundant safeguard:
```bash
kubectl annotate node "$NODENAME" io.cilium.aws/exclude-from-eni-allocation=true --overwrite
```

---

## 18. CoreDNS scheduled on master — unreachable from worker pods

**Issue**: CoreDNS pods get IPs in the pod subnet (`10.0.4.x`) but run on the master where the pod-subnet ENI is disabled. Worker pods cannot reach CoreDNS, causing DNS resolution failures and Hubble relay crash loops:
```
dial tcp: lookup hubble-peer.kube-system.svc.cluster.local. on 10.96.0.10:53: i/o timeout
```

**Root Cause**:
- CoreDNS was scheduled on the master before the `NoSchedule` taint was applied
- With the master's pod-subnet ENI disabled (fix for Issue #17), pods on workers cannot route traffic to pod IPs hosted on the master

**Resolution**:
- Patched CoreDNS deployment with nodeAffinity to exclude control-plane nodes, added to `master-runtime.sh` after taint/annotation block:
```bash
kubectl -n kube-system patch deployment coredns --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/affinity","value":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/control-plane","operator":"DoesNotExist"}]}]}}}}]' 2>/dev/null || true
```

---

## 19. OpenEBS Helm timeout kills master-runtime.sh — auto-labeler never runs

**Issue**: Node labels (`minio-worker`, `spark-worker`, etc.) never applied. Pods with node selectors stuck in `Pending` with:
```
0/5 nodes are available: 4 node(s) didn't match Pod's node affinity/selector
```

**Root Cause**:
- OpenEBS Helm install fails with `timed out waiting for the condition` (post-install hooks can't reach API server during initial cluster setup)
- `set -euxo pipefail` at top of `master-runtime.sh` causes the entire script to abort on this non-zero exit
- Everything after OpenEBS — auto-label-nodes systemd service, k8s-auto-label service — never gets created

**Resolution**:
- Added `|| true` to the OpenEBS Helm install so the script continues even if post-install hooks timeout:
```bash
helm upgrade --install openebs openebs/openebs \
  --namespace openebs --create-namespace \
  --set engines.replicated.mayastor.enabled=false \
  --set engines.local.zfs.enabled=false \
  --set engines.local.lvm.enabled=false || true
```

---

## 20. etcd EBS volume too small — future disk exhaustion risk

**Issue**: Not yet triggered, but etcd configured with `quota-backend-bytes: 2147483648` (2GB) on a 2GB dedicated EBS volume. WAL files + snapshots + DB would fill the disk, causing etcd to go read-only and freeze the cluster.

**Root Cause**:
- Dedicated etcd EBS volume in Terraform was `volume_size = 2` with etcd quota set to the full disk size
- No room for WAL files and snapshots

**Resolution**:
- Increased EBS to `volume_size = 10` in `master.tf`
- Reduced etcd quota to `1073741824` (1GB) in `master-runtime.sh`
- Updated Terraform etcd device size detection range from `1GB-3GB` to `5GB-11GB`

---

## 21. EC2 user-data 16KB limit — silent script truncation risk

**Issue**: Total user-data size was 16,288 bytes — only 96 bytes under the 16,384-byte AWS limit. Any minor addition would cause silent truncation with no error.

**Root Cause**:
- Terraform user-data embeds two base64-encoded shell scripts (`common-runtime.sh` + `master-runtime.sh`) plus inline etcd mount logic
- Base64 encoding inflates size by ~33%

**Resolution**:
- Changed from `user_data = <<-EOF` to `user_data_base64 = base64gzip(local.master_userdata)` in `master.tf`
- Gzip compression reduces payload by 60-70%, providing ample headroom for future changes

---

# EKS Migration Issues (Post Issue #21)

The following issues were encountered after migrating the control plane from self-managed EC2 master to AWS EKS with self-managed worker nodes.

---

## 22. KubeletConfiguration API version mismatch (v1 vs v1beta1)

**Issue**: Kubelet fails to start with:
```
no kind "KubeletConfiguration" is registered for version "kubelet.config.k8s.io/v1"
```

**Root Cause**:
- K8s 1.34 kubelet does NOT yet support `kubelet.config.k8s.io/v1` for KubeletConfiguration — only `v1beta1` is registered
- The bootstrap script was initially written with `v1` assuming 1.34 had graduated it

**Resolution**:
- Changed `apiVersion` in `/var/lib/kubelet/config.yaml` from `kubelet.config.k8s.io/v1` to `kubelet.config.k8s.io/v1beta1` in `worker-eks-bootstrap.sh`

---

## 23. Missing `interactiveMode` in exec credential plugin

**Issue**: Kubelet fails to start with:
```
interactiveMode must be specified for kubelet to use exec authentication plugin
```

**Root Cause**:
- K8s 1.34 kubelet requires the `interactiveMode` field in the exec credential config inside kubeconfig
- Without it, kubelet refuses to initialize the exec-based token provider (`aws eks get-token`)

**Resolution**:
- Added `interactiveMode: Never` under the `exec:` section in the kubelet kubeconfig in `worker-eks-bootstrap.sh`:
```yaml
users:
- name: kubelet
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: /usr/local/bin/aws
      interactiveMode: Never
      args:
        - eks
        - get-token
        - --cluster-name
        - k8s-dev-cluster
```

---

## 24. Kubelet stuck silently — `--bootstrap-kubeconfig` incompatible with exec credentials

**Issue**: Kubelet logs one `Failed to connect to apiserver` message with 1-second timeout, then goes completely silent. No further logs. Process sleeping on futex with only 1.05s CPU over 4+ minutes.

**Root Cause**:
- `--bootstrap-kubeconfig` was pointing to the same exec-credential kubeconfig as `--kubeconfig`
- This triggered the TLS bootstrap flow, which is fundamentally incompatible with exec-based authentication (aws eks get-token)
- Kubelet entered an internal retry loop against the bootstrap path, hitting a 1s healthz timeout each cycle, with no logs emitted after the first failure
- Network was fine (curl to EKS endpoint with CA cert worked), confirming the issue was in kubelet's bootstrap logic, not connectivity

**Diagnosis**:
- `journalctl -u kubelet` showed only one line then silence
- `cat /proc/<pid>/stack` showed futex sleep
- `curl --cacert /etc/kubernetes/pki/ca.crt https://<eks-endpoint>` returned 200 from the node
- CPU time analysis: 1.05s CPU over 4+ minutes = stuck, not busy-looping

**Resolution**:
- Removed `--bootstrap-kubeconfig` flag entirely from the kubelet systemd drop-in (`20-eks.conf`)
- With exec credentials (`aws eks get-token`), kubelet authenticates directly — TLS bootstrap is not needed or supported
- The golden AMI's base `10-kubeadm.conf` drop-in included `--bootstrap-kubeconfig`; the new `20-eks.conf` overrides it with `ExecStart=` (clear) followed by a clean ExecStart without the flag

---

## 25. Cilium CrashLoopBackOff — BPF masquerade requires enableIPv4Masquerade

**Issue**: Cilium agent pods crash with:
```
BPF masquerade requires --enable-ipv4-masquerade="true"
```

**Root Cause**:
- `bpf.masquerade=true` was set in the Cilium Helm values for optimal ENI-mode performance
- However, `enableIPv4Masquerade` defaults to `false` in ENI mode
- BPF masquerade is an implementation of masquerade — it cannot work if the base masquerade feature is disabled

**Resolution**:
- Added `--set enableIPv4Masquerade=true` to the Cilium Helm install in `post-cluster-bootstrap.sh`:
```bash
helm upgrade --install cilium cilium/cilium \
  --set enableIPv4Masquerade=true \
  --set bpf.masquerade=true
```

---

## 26. kube-proxy ImagePullBackOff — ECR auth failure (not needed with Cilium)

**Issue**: kube-proxy pods stuck in ImagePullBackOff:
```
Failed to pull image "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/kube-proxy:v1.34.0-eksbuild.2"
```

**Root Cause**:
- EKS automatically creates a kube-proxy DaemonSet that pulls from private ECR
- The golden AMI does not have the `ecr-credential-provider` binary, so kubelet cannot authenticate to ECR
- kube-proxy is redundant when Cilium runs with `kubeProxyReplacement=true`

**Resolution**:
- Deleted kube-proxy DaemonSet and ConfigMap entirely — not needed with Cilium KPR
- Added deletion as Step 4b in `post-cluster-bootstrap.sh`:
```bash
kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found
kubectl -n kube-system delete configmap kube-proxy --ignore-not-found
```

---

## 27. CoreDNS ErrImagePull — ECR credential provider missing from golden AMI

**Issue**: CoreDNS pods stuck in ErrImagePull:
```
Failed to pull image "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.12.3-eksbuild.1"
```

**Root Cause**:
- Same ECR auth failure as kube-proxy (Issue #26), but CoreDNS cannot simply be deleted — it is required for cluster DNS
- `ecr-credential-provider` binary is not installed on the golden AMI (`k8s-ubuntu-2404-arm64-golden-v2`)
- Without it, kubelet has no way to authenticate to private ECR registries

**Workaround** (applied in `worker-eks-bootstrap.sh`):
- If `ecr-credential-provider` binary is not found, pre-pull the CoreDNS image using containerd CLI with a temporary ECR token:
```bash
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
ctr -n k8s.io image pull --user "AWS:${ECR_PASSWORD}" \
  "602401143452.dkr.ecr.${AWS_REGION}.amazonaws.com/eks/coredns:v1.12.3-eksbuild.1"
```

**Permanent fix**: Added `ecr-credential-provider` binary (from `kubernetes/cloud-provider-aws` releases, pinned to `v1.34.0`) to the golden AMI Packer build in `packer/common-ami.sh` section 11. The bootstrap script (`worker-eks-bootstrap.sh`) detects this binary and configures kubelet's `--image-credential-provider-config` and `--image-credential-provider-bin-dir` flags automatically. The `ctr` pre-pull path remains as a fallback for older AMIs without the binary.

---

## 28. CoreDNS CrashLoopBackOff — DNS forwarding loop with systemd-resolved

**Issue**: CoreDNS pods in CrashLoopBackOff with:
```
Loop (127.0.0.1:42583 -> :53) detected for zone "."
```

**Root Cause**:
- CoreDNS ConfigMap had `forward . /etc/resolv.conf`
- On Ubuntu 24.04 nodes running systemd-resolved, `/etc/resolv.conf` is a symlink to `/run/systemd/resolve/stub-resolv.conf` which contains `nameserver 127.0.0.53`
- `127.0.0.53` (systemd-resolved) forwards DNS to the cluster DNS (CoreDNS via ClusterIP `172.20.0.10`), creating an infinite loop:
  ```
  CoreDNS → /etc/resolv.conf → 127.0.0.53 → cluster DNS → CoreDNS → ∞
  ```

**Resolution**:
- Patched CoreDNS ConfigMap to forward to VPC DNS resolver instead of `/etc/resolv.conf`
- VPC DNS is always at VPC CIDR base + 2 = `10.0.0.2`
- Added as Step 4c in `post-cluster-bootstrap.sh`:
```bash
kubectl -n kube-system get configmap coredns -o yaml | \
  sed 's|forward . /etc/resolv.conf|forward . 10.0.0.2|' | \
  kubectl apply -f - || true
kubectl -n kube-system rollout restart deployment coredns || true
```
---

## 29. Cilium ENI Allocation Failure — IMDS Hop Limit Too Low

**Issue**: Cilium operator failed to allocate ENIs (Elastic Network Interfaces) for pod secondary IPs, causing critical cluster failure:
- Cilium agent pods: `CrashLoopBackOff` (timed out waiting for CRD events after 3m0s)
- CoreDNS: `Pending` (no IPs to schedule)
- Hubble Relay: `Pending` (same root cause)
- `CiliumNode` objects: Empty `CILIUMINTERNALIP` column (no IPs allocated to any node)

**Root Cause**:
The Cilium operator pod needs AWS credentials to call EC2 APIs (`CreateNetworkInterface`, `AttachNetworkInterface`, `AssignPrivateIpAddresses`) to allocate secondary ENIs for pod IPs. The operator obtains credentials from the **node's IAM role via IMDS** (Instance Metadata Service). However, the request path requires crossing a network namespace boundary:

```
Pod network namespace → Host network namespace → IMDS (169.254.169.254)
                    ↑ hop 1                    ↑ hop 2
```

The EC2 instance default `http_put_response_hop_limit` is **1**, allowing only direct requests. Pods need **hop limit 2** to traverse the namespace boundary.

**Result**: IMDS returned 404 ("TTL expired") → operator couldn't get credentials → operator never attempted EC2 API calls (no error logs visible) → cilium-agent had no IPs available → agent timed out waiting for CRD initialization and crashed.

**Operator Logs Evidence**:
```
time=2026-03-22T12:50:00.534901907Z level=info msg="Leader re-election complete" module=operator newLeader=ip-10-0-2-105-mtvdl55cm4
```
Operator logs ended immediately after leadership election — no ENI allocation activity logged, confirming silent credential failure.

**Fix Applied**:
Added `metadata_options` to all 4 worker launch templates with `http_put_response_hop_limit = 2`:

**Files modified:**
- `compute-spark-critical.tf`
- `compute-k8s-gp.tf`
- `compute-spark-spot.tf`
- `compute-minio.tf`

**Change:**
```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"   # IMDSv2 enforced
  http_put_response_hop_limit = 2            # allows pods to reach IMDS
}
```

**Deployment Steps**:
1. Run `terraform apply` to update launch templates (creates new version)
2. Terminate existing worker nodes to force ASG replacement:
   ```bash
   aws ec2 terminate-instances --instance-ids <id1> <id2> <id3> <id4> --region us-east-1
   ```
3. Wait 5-10 minutes for new nodes to register
4. Restart Cilium:
   ```bash
   kubectl -n kube-system rollout restart daemonset cilium
   kubectl -n kube-system rollout restart deployment cilium-operator
   ```
5. Verify CiliumNode IPs are allocated:
   ```bash
   kubectl get ciliumnode -o wide
   # Should show IPs in CILIUMINTERNALIP column
   ```

**Why This Matters for EKS**:
- Cilium ENI mode is optimal for EKS self-managed nodes (AWS-native networking, no VXLAN overhead)
- Pod IMDS access is required for any AWS SDK client (credentials for application services)
- IMDSv2 (token-based) is enforced for security; hop limit 2 is still required
- **Common gotcha** on EKS with CNIs requiring ENI operations (Cilium, AWS VPC CNI if configured with custom ENIs)

---

## 30. ECR Credential Provider Missing from Golden AMI (Build from Source)

**Issue**: Kubelet unable to authenticate to AWS ECR for pulling EKS-managed container images:
```
Failed to pull image "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.12.3-eksbuild.1"
Failed to pull image "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/kube-proxy:v1.34.0-eksbuild.2"
```

**Root Cause**:
- EKS provides managed container images in private AWS ECR registries
- Kubelet needs the `ecr-credential-provider` binary to dynamically fetch ECR auth tokens via the image credential provider API
- Neither pre-built binaries nor OCI images exist in public registries for Kubernetes v1.32+ (including v1.34)
- The golden AMI (`k8s-ubuntu-2404-arm64-golden-v2`) did not include the credential provider, blocking all ECR image pulls

**Initial Workaround** (in `worker-eks-bootstrap.sh`):
- For nodes without the credential provider, pre-pull the CoreDNS image using containerd CLI with a temporary ECR token:
```bash
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
ctr -n k8s.io image pull --user "AWS:${ECR_PASSWORD}" \
  "602401143452.dkr.ecr.${AWS_REGION}.amazonaws.com/eks/coredns:v1.12.3-eksbuild.1"
```
This only pulls CoreDNS; other images still fail.

**Permanent Fix** (in `packer/common-ami.sh`, Section 11):
- Build `ecr-credential-provider` from official upstream source (`kubernetes/cloud-provider-aws`) instead of relying on non-existent pre-built releases
- Go compiler installed temporarily, used only for the build, then removed to keep the AMI clean
- Implementation:

```bash
echo "Building ECR credential provider $ECR_CRED_VERSION from source..."

GO_VERSION="go1.23.8"
GOARCH_VALUE="$(dpkg --print-architecture)"   # arm64 or amd64
GO_TARBALL="/tmp/${GO_VERSION}.linux-${GOARCH_VALUE}.tar.gz"

wget -q "https://go.dev/dl/${GO_VERSION}.linux-${GOARCH_VALUE}.tar.gz" -O "${GO_TARBALL}"
sudo tar -C /usr/local -xzf "${GO_TARBALL}"
export PATH=$PATH:/usr/local/go/bin
export GOPATH=/tmp/gopath
export GOCACHE=/tmp/gocache

git clone --depth 1 --branch "${ECR_CRED_VERSION}" \
    https://github.com/kubernetes/cloud-provider-aws.git /tmp/cloud-provider-aws

cd /tmp/cloud-provider-aws
CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH_VALUE}" \
    /usr/local/go/bin/go build \
    -ldflags="-s -w" \
    -o /tmp/ecr-credential-provider \
    ./cmd/ecr-credential-provider
cd -

sudo install -m 0755 /tmp/ecr-credential-provider /usr/local/bin/ecr-credential-provider

# Purge everything the build touched — no Go bloatware in final AMI
sudo rm -rf \
    /usr/local/go \
    "${GO_TARBALL}" \
    /tmp/cloud-provider-aws \
    /tmp/ecr-credential-provider \
    /tmp/gopath \
    /tmp/gocache \
    /root/.cache/go-build \
    /root/go \
    /home/ubuntu/.cache/go-build \
    /home/ubuntu/go
```

**Key Decisions**:
- **Build from source**: Kubernetes v1.34 has no pre-built release of `ecr-credential-provider`; building is the only reliable solution
- **Cross-architecture support**: Script detects `dpkg --print-architecture` (arm64 or amd64) to download matching Go toolchain and build with correct `GOARCH`
- **Clean AMI**: Go compiler and source code removed after build — final binary is ~50MB stripped, no dev toolchain bloat
- **Pinned versions**: `ECR_CRED_VERSION=v1.34.0` matched to Kubernetes version; `GO_VERSION=go1.23.8` validated stable for this build
- **Verification**: Final Packer step verifies `ecr-credential-provider version` or `ecr-credential-provider --version` output

**Integration in worker-eks-bootstrap.sh**:
Once the binary is available in the AMI, `worker-eks-bootstrap.sh` configures kubelet to use it:
```bash
cat > /etc/kubernetes/image-credential-provider-config.json <<EOF
{
  "providers": [
    {
      "name": "ecr-credential-provider",
      "matchImages": [
        "*.dkr.ecr.*.amazonaws.com",
        "*.dkr.ecr.*.amazonaws.com.cn"
      ],
      "defaultCacheDuration": "1h",
      "apiVersion": "credentialprovider.kubelet.k8s.io/v1"
    }
  ]
}
EOF

# Kubelet flags (in systemd drop-in 20-eks.conf)
--image-credential-provider-config=/etc/kubernetes/image-credential-provider-config.json \
--image-credential-provider-bin-dir=/usr/local/bin
```

**Result**:
- ✅ CoreDNS, kube-proxy, and all EKS-managed images pull successfully from ECR
- ✅ No pre-pull workaround needed
- ✅ Kubelet auto-refreshes ECR tokens every 1 hour (configurable)
- ✅ AMI remains clean — no Go/build artifacts, only ~50MB stripped binary

**Why This Matters**:
- **Kubernetes v1.32+ compatibility**: Newer k8s versions remove pre-built credential provider releases; source build is the only path
- **EKS with self-managed nodes**: This pattern applies to ANY EKS cluster with custom AMIs and private ECR images
- **Multi-architecture**: Build script handles both ARM64 (Graviton c7g) and x86 (c6i, m5) instances automatically
---

## Issue: Cilium Cross-Node Endpoint Health Check Failure

**Status**: ONGOING (2026-03-23)

**Symptom**:
- `cilium-health status` shows only 1/4 nodes reachable
- Node health check (TCP 4240 on 10.0.2.x) partially working: 1/4 reachable
- Endpoint health check (TCP 4240 on 10.0.4.x pod IPs) completely broken: 0/1 reachable on all remote nodes
- Local node endpoint 1/1 reachable (node can reach its own pods)
- Health endpoints detected on all 4 nodes: 10.0.4.14, 10.0.4.21, 10.0.4.186, 10.0.4.68

**Evidence**:
- Cilium 1.19.1 installed on all nodes via Helm after kube-proxy deletion
- All Cilium DaemonSet pods running (no crashes/restarts observed)
- Secondary ENIs correctly configured in pod subnet (subnet-0f80a77648d2d6820)
- Security groups identical on primary and secondary ENIs (sg-07eb867966a2233c6 + sg-03393dc121a22a671)
- Secondary IPs correctly allocated in AWS (15 IPs per node in 10.0.4.0/24)
- Pod subnet ID in Cilium values updated post-Helm-upgrade: `eni.subnetIDsFilter[0]=subnet-0f80a77648d2d6820`

**Critical Finding**:
- One health endpoint (10.0.4.186 on cilium-lt27p) vanished during diagnostics
- `kubectl -n kube-system exec cilium-lt27p -c cilium-agent -- cilium endpoint list | grep health` returned EMPTY
- Suggests endpoints may be flapping or not stabilizing after Helm upgrade with corrected subnet ID

**Root Cause (Unknown)**:
Could be any of:
1. **Pod-level networking issue**: source_dest_check on secondary ENIs not properly disabled, or eBPF/BPF masquerade misconfiguration
2. **Cilium agent initialization**: Endpoints not fully initialized after Helm upgrade; needs more time to converge
3. **Subnet ID propagation**: Helm upgrade with new subnet ID not fully propagated to running Cilium agents
4. **ENI allocation race**: Secondary ENI allocation not synced with endpoint lifecycle

**Next Steps**:
1. Cross-node endpoint connectivity test (from GP worker via SSM):
   ```bash
   curl -s --connect-timeout 3 http://10.0.4.14:4240/hello
   curl -s --connect-timeout 3 http://10.0.4.21:4240/hello
   curl -s --connect-timeout 3 http://10.0.4.186:4240/hello
   curl -s --connect-timeout 3 http://10.0.4.68:4240/hello
   ```
   - If timeouts → VPC-level pod networking issue (check source_dest_check, eBPF/BPF masquerade)
   - If succeeds → Cilium just needs time to stabilize endpoints

2. Check Cilium pod stability:
   ```bash
   kubectl -n kube-system get pods -l k8s-app=cilium
   kubectl -n kube-system logs cilium-lt27p --tail=20  # Check for errors
   kubectl -n kube-system logs cilium-operator-... --tail=20
   ```

3. Force Cilium endpoint update (if time stabilization is the issue):
   ```bash
   kubectl -n kube-system rollout restart daemonset/cilium
   sleep 60
   cilium-health status
   ```

**Architecture Context**:
- 4 worker nodes in private subnet (10.0.2.0/24)
- Cilium ENI mode: pods get IPs from pod subnet (10.0.4.0/24) via secondary ENI allocation
- Node-to-pod communication requires:
  - source_dest_check=false on both primary and secondary ENIs
  - eBPF/BPF masquerade enabled for packet rewriting
  - Pod security group (sg-03393dc121a22a671) allows ingress on Cilium health port (4240)
  - No NACLs blocking 10.0.2.x ↔ 10.0.4.x cross-subnet traffic

**Impact**:
- Cross-node pod communication likely broken (endpoints unreachable)
- Cluster DNS, service load balancing, and inter-pod communication degraded
- Workloads unable to reach endpoints on remote nodes (will stay local or fail)

**Workarounds**:
- None yet identified; requires root cause diagnosis

**Related Commits**:
- `fec3795`: Build ECR credential provider from source and fix pod IMDS access for Cilium ENI
- `b378136`: Replace AWS NAT Gateway with fck-nat cost-optimized instance + post-cluster-bootstrap restructure
