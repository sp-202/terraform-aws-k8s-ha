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

variable "kubernetes_version" {
  type    = string
  default = "v1.34"
}

source "amazon-ebs" "k8s_node" {
  ami_name      = "k8s-ubuntu-2404-arm64-golden-v2-{{timestamp}}"
  # t4g.medium — cheap ARM64 builder, instance metadata wiped at end so type doesn't matter
  instance_type = "t4g.medium"
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

  # 40GB root — enough for k8s images, containerd layers, logs
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 40
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # IMDSv2 enforced on builder too — matches prod security posture
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name              = "k8s-golden-ami-arm64"
    Environment       = "production"
    CreatedBy         = "packer"
    KubernetesVersion = "1.34"
    CiliumVersion     = "1.16.5"
  }
}

build {
  name = "k8s-golden-builder"
  sources = [
    "source.amazon-ebs.k8s_node"
  ]

  # Step 1 — Wait for cloud-init before doing anything
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait"
    ]
  }

  # Step 2 — Upload common-ami.sh
  provisioner "file" {
    source      = "common-ami.sh"
    destination = "/tmp/common-ami.sh"
  }

  # Step 3 — Run common-ami.sh (k8s, containerd, cilium-cli, helm)
  provisioner "shell" {
    inline = [
      "chmod +x /tmp/common-ami.sh",
      "sudo bash -c 'export KUBERNETES_VERSION=${var.kubernetes_version}; /tmp/common-ami.sh'"
    ]
  }

  # Step 4 — Install AWS CLI v2 (arch-aware)
  provisioner "shell" {
    inline = [
      "echo 'Installing AWS CLI v2...'",
      "sudo apt-get install -y unzip",
      "if [ \"$(uname -m)\" = \"aarch64\" ]; then",
      "  curl -sL https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o awscliv2.zip",
      "else",
      "  curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip",
      "fi",
      "unzip -q awscliv2.zip",
      "sudo ./aws/install",
      "rm -rf awscliv2.zip aws/",
      "aws --version"
    ]
  }

  # Step 5 — MUST BE LAST: Wipe all instance-specific state
  # This makes the AMI fully generic — works on ANY ARM64 instance type
  # Cilium will detect correct instance type from live IMDS at boot time
  provisioner "shell" {
    inline = [
      "echo 'Wiping instance-specific state for generic AMI...'",

      # Stop services that may have cached instance metadata
      "sudo systemctl stop containerd || true",

      # Cloud-init clean — forces full re-run on next boot with correct instance identity
      "sudo cloud-init clean --logs --seed",
      "sudo rm -rf /var/lib/cloud/instances/",
      "sudo rm -rf /var/lib/cloud/data/",
      "sudo rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log",

      # Reset machine-id — each instance gets a unique one on first boot
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",

      # Remove SSH host keys — regenerated on first boot per instance
      "sudo rm -f /etc/ssh/ssh_host_*",

      # Clean apt cache and package lists
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",

      # Remove any AWS credentials or config cached during build
      "sudo rm -rf /root/.aws /home/ubuntu/.aws",

      # Clean temp files
      "sudo rm -rf /tmp/* /var/tmp/*",

      # Clean shell history
      "sudo truncate -s 0 /root/.bash_history || true",
      "truncate -s 0 /home/ubuntu/.bash_history || true",

      "echo 'AMI generalization complete. Ready for snapshot.'"
    ]
  }
}