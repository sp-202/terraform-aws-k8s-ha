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
    CiliumVersion     = "1.19.1"
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
  # This makes the AMI fully generic — works on ANY ARM64 instance type.
  # Every item below is state produced by the builder EC2 instance that must
  # NOT be frozen into the snapshot, otherwise new instances boot with stale
  # identity (wrong instance-id, IP, MAC, hostname, entropy, etc.)
  provisioner "shell" {
    inline = [
      "echo 'Wiping instance-specific state for generic AMI...'",

      # ── Services ────────────────────────────────────────────────────────────
      # Stop everything that holds open state before we wipe it
      "sudo systemctl stop containerd kubelet || true",

      # ── containerd state ────────────────────────────────────────────────────
      # containerd ran during the build (--now flag). Its content store and
      # snapshotter track the builder's on-disk state. New instances must start
      # fresh — containerd re-initialises from an empty dir on first start.
      "sudo rm -rf /var/lib/containerd/",

      # ── Cloud-init ──────────────────────────────────────────────────────────
      # Forces full re-run on next boot so the new instance picks up its own
      # instance-id, hostname, SSH keys, and user-data from IMDS.
      "sudo cloud-init clean --logs --seed",
      "sudo rm -rf /var/lib/cloud/",
      "sudo rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log",

      # ── Machine identity ────────────────────────────────────────────────────
      # machine-id must be unique per instance. Truncating (not deleting)
      # causes systemd to regenerate it on first boot.
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",

      # ── Hostname ────────────────────────────────────────────────────────────
      # EC2 sets the builder hostname to ip-10-x-x-x.region.compute.internal.
      # Reset to a neutral placeholder; cloud-init overwrites it on first boot.
      "echo 'localhost' | sudo tee /etc/hostname",
      "sudo sed -i '/^127\\.0\\.0\\.1/c\\127.0.0.1 localhost' /etc/hosts",
      "sudo sed -i '/ip-[0-9]/d' /etc/hosts",

      # ── SSH host keys ───────────────────────────────────────────────────────
      # Host keys are per-machine secrets. cloud-init regenerates them on boot.
      "sudo rm -f /etc/ssh/ssh_host_*",

      # ── Network state ───────────────────────────────────────────────────────
      # DHCP leases bind the builder's MAC address and IP — useless on a
      # different instance type that gets a different ENI.
      "sudo rm -f /var/lib/dhcp/*.leases 2>/dev/null || true",
      # NetworkManager caches interface names/MACs from the builder NIC.
      "sudo rm -rf /var/lib/NetworkManager/ 2>/dev/null || true",
      # systemd-networkd persisted state (interface leases, etc.)
      "sudo rm -rf /var/lib/systemd/network/ 2>/dev/null || true",

      # ── Entropy seed ────────────────────────────────────────────────────────
      # The random seed is derived from the builder's hardware. Each new
      # instance must generate its own to avoid predictable randomness.
      "sudo rm -f /var/lib/systemd/random-seed",

      # ── System logs ─────────────────────────────────────────────────────────
      # Journal contains the builder's instance-id, private IP, and AZ in
      # every log line. Wipe it so node logs start clean on first boot.
      "sudo journalctl --flush 2>/dev/null || true",
      "sudo rm -rf /var/log/journal/",
      # Truncate (not delete) other logs — some init scripts expect the files
      "sudo find /var/log -type f ! -name '*.gz' -exec truncate -s 0 {} \\;",

      # ── APT cache ───────────────────────────────────────────────────────────
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",

      # ── AWS credentials ─────────────────────────────────────────────────────
      "sudo rm -rf /root/.aws /home/ubuntu/.aws",

      # ── Temp / scratch ──────────────────────────────────────────────────────
      "sudo rm -rf /tmp/* /var/tmp/*",

      # ── Shell history ───────────────────────────────────────────────────────
      "sudo truncate -s 0 /root/.bash_history || true",
      "truncate -s 0 /home/ubuntu/.bash_history || true",

      "echo 'AMI generalization complete. Ready for snapshot.'"
    ]
  }
}