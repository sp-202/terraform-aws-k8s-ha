packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

source "amazon-ebs" "k8s_node" {
  ami_name      = "k8s-ubuntu-2404-arm64-golden-v1-{{timestamp}}"
  instance_type = "c7g.xlarge"
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }

  ssh_username = "ubuntu"
  
  # Ensure the builder instance has enough space and matches our prod environment
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 40
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "k8s-golden-ami-arm64"
    Environment = "production"
    CreatedBy   = "packer"
  }
}

build {
  name    = "k8s-golden-builder"
  sources = [
    "source.amazon-ebs.k8s_node"
  ]

  # Provisioning Steps
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait"
    ]
  }

  provisioner "file" {
    source      = "common-ami.sh"
    destination = "/tmp/common-ami.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/common-ami.sh",
      "sudo bash -c 'export KUBERNETES_VERSION=v1.34; /tmp/common-ami.sh'",
      
      # Now, additionally pre-install AWS CLI and Unzip so worker nodes don't need to do it at boot
      "echo 'Pre-installing unzip and awscli v2...'",
      "sudo apt-get update -y && sudo apt-get install -y unzip",
      "if [ \"$(uname -m)\" = \"aarch64\" ]; then curl -sL \"https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip\" -o \"awscliv2.zip\"; else curl -sL \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\"; fi",
      "unzip -q awscliv2.zip",
      "sudo ./aws/install",
      "rm -rf awscliv2.zip aws/"
    ]
  }
}
