#!/bin/bash
set -e

echo "Initializing Packer plugins..."
packer init k8s-golden-ami.pkr.hcl

echo "Baking Golden K8s ARM64 AMI..."
packer build k8s-golden-ami.pkr.hcl
