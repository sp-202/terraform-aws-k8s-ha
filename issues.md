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
