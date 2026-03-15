resource "aws_key_pair" "k8s_key" {
  key_name   = "${var.cluster_name}-access-key"
  public_key = file(var.ssh_public_key_path)
}

resource "random_string" "kubeadm_token_1" {
  length  = 6
  special = false
  upper   = false
}

resource "random_string" "kubeadm_token_2" {
  length  = 16
  special = false
  upper   = false
}

locals {
  kubeadm_token = "${random_string.kubeadm_token_1.result}.${random_string.kubeadm_token_2.result}"
}

# k8s master node
resource "aws_instance" "master" {
  ami           = data.aws_ami.golden.id
  instance_type = var.master_instance_type
  subnet_id     = aws_subnet.public.id
  key_name      = aws_key_pair.k8s_key.key_name

  user_data_replace_on_change = true

  vpc_security_group_ids = [aws_security_group.master_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.node_profile.name
  source_dest_check      = false

  # Master 80GB EBS Root Volume
  root_block_device {
    volume_size           = 80
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Dedicated 2GB EBS for etcd — isolates etcd I/O from image pulls
  ebs_block_device {
    device_name           = "/dev/xvdf"
    volume_size           = 2
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

              echo "Starting Master User Data..."

              echo "${base64encode(file("${path.module}/scripts/common-runtime.sh"))}" | base64 -d > /root/common-runtime.sh
              echo "${base64encode(file("${path.module}/scripts/master-runtime.sh"))}" | base64 -d > /root/master-runtime.sh

              chmod +x /root/common-runtime.sh /root/master-runtime.sh

              # --- Mount dedicated etcd EBS volume ---
              echo "Mounting dedicated etcd EBS volume..."
              # AWS Nitro exposes EBS as NVMe; find the device mapped to xvdf
              ETCD_DEV=""
              for i in $(seq 1 30); do
                for dev in /dev/nvme*n1; do
                  SERIAL=$(sudo nvme id-ctrl "$dev" 2>/dev/null | grep -i sn | awk -F':' '{print $2}' | xargs || true)

                  # Fallback: check lsblk for 2G unformatted disk
                  SIZE=$(lsblk -bdno SIZE "$dev" 2>/dev/null || echo 0)
                  MODEL=$(sudo nvme id-ctrl "$dev" 2>/dev/null | grep -i mn | awk -F':' '{print $2}' | xargs || true)
                  # EBS volumes show as "Amazon Elastic Block Store"
                  if [[ "$MODEL" == *"Elastic Block"* ]] && [ "$SIZE" -le 3000000000 ] && [ "$SIZE" -gt 1000000000 ]; then
                    MOUNT_CHECK=$(mount | grep -c "$dev" || true)
                    if [ "$MOUNT_CHECK" -eq 0 ]; then
                      ETCD_DEV="$dev"
                      break 2
                    fi
                  fi
                done
                echo "Waiting for etcd EBS device... attempt $i"
                sleep 2
              done

              if [ -n "$ETCD_DEV" ]; then
                echo "Found etcd EBS device: $ETCD_DEV"
                # Format as ext4 if not already formatted
                FSTYPE=$(lsblk -no FSTYPE "$ETCD_DEV" 2>/dev/null || true)
                if [ -z "$FSTYPE" ]; then
                  sudo mkfs.ext4 -F "$ETCD_DEV"
                fi
                sudo mkdir -p /var/lib/etcd
                sudo mount -o noatime "$ETCD_DEV" /var/lib/etcd
                echo "$ETCD_DEV /var/lib/etcd ext4 defaults,noatime 0 0" >> /etc/fstab
                sudo chmod 0700 /var/lib/etcd
                echo "etcd EBS mounted at /var/lib/etcd"
              else
                echo "WARNING: etcd EBS device not found, falling back to root volume"
                sudo mkdir -p /var/lib/etcd
                sudo chmod 0700 /var/lib/etcd
              fi

              # Run common-runtime.sh
              /root/common-runtime.sh

              # Modify master-runtime.sh
              sed -i 's/PUBLIC_IP_ACCESS="false"/PUBLIC_IP_ACCESS="true"/' /root/master-runtime.sh
              # Inject bootstrap token into kubeadm config
              sed -i 's/__BOOTSTRAP_TOKEN__/${local.kubeadm_token}/' /root/master-runtime.sh
              sed -i 's|__POD_CIDR__|${var.pod_subnet_cidr}|g' /root/master-runtime.sh
              sed -i 's|__POD_SUBNET_ID__|${aws_subnet.pods.id}|g' /root/master-runtime.sh

              # Run master-runtime.sh
              /root/master-runtime.sh

              # Exclude master from Cilium ENI IP pre-warming to prevent ens6 ENI leak
              export KUBECONFIG=/etc/kubernetes/admin.conf
              kubectl annotate node $(hostname -s) \
                "io.cilium.aws/exclude-from-eni-allocation=true" || true

              # Copy config for ubuntu user
              mkdir -p /home/ubuntu/.kube
              cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
              chown -R ubuntu:ubuntu /home/ubuntu/.kube
              chmod 600 /home/ubuntu/.kube/config

              echo "User Data Complete."
              EOF

  tags = {
    Name = "${var.cluster_name}-master"
    Role = "master"
  }

  depends_on = [
    aws_subnet.pods,
    aws_route_table_association.public,
    aws_iam_role_policy_attachment.node_attach
  ]
}
