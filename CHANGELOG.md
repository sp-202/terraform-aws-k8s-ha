# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]
### Added
- Created `dev.tfvars` and `prod.tfvars` to explicitly separate environment deployments automatically without hardcoding values in the compute modules.
- Extracted EC2 instance types and worker counts into parameterizable `variables.tf` properties.
- Support for scaled-down cluster deployments using smaller AWS Graviton sizes (e.g. `c6gd.2xlarge`).
- Documented explicit component versions in README.md (Kubernetes v1.34, Cilium v1.19.1, Containerd 2.0).

### Fixed
- Fixed a control plane deadlock where `etcd` and `kube-apiserver` crash-looped randomly due to Cilium AWS ENI IPAM hijacking local kernel routing. Added a pre-boot `ip route replace local` workaround to `common-runtime.sh` ensuring stable primary IP routing.
- Relaxed strict validation rules on ASG inputs in `variables.tf` to permit single-node worker deployments for testing environments.
