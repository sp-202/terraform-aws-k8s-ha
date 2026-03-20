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

  master_userdata = <<-USERDATA
    #!/bin/bash
    set -ex
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

    echo "Starting Master User Data..."

    echo "${base64encode(file("${path.module}/scripts/common-runtime.sh"))}" | base64 -d > /root/common-runtime.sh
    echo "${base64encode(file("${path.module}/scripts/master-runtime.sh"))}" | base64 -d > /root/master-runtime.sh

    chmod +x /root/common-runtime.sh /root/master-runtime.sh

    # --- Mount dedicated etcd EBS volume ---
    ETCD_DEV=""
    for i in $(seq 1 30); do
      for dev in /dev/nvme*n1; do
        SIZE=$(lsblk -bdno SIZE "$dev" 2>/dev/null || echo 0)
        MODEL=$(sudo nvme id-ctrl "$dev" 2>/dev/null | grep -i mn | awk -F':' '{print $2}' | xargs || true)
        if [[ "$MODEL" == *"Elastic Block"* ]] && [ "$SIZE" -le 11000000000 ] && [ "$SIZE" -gt 5000000000 ]; then
          MOUNT_CHECK=$(mount | grep -c "$dev" || true)
          if [ "$MOUNT_CHECK" -eq 0 ]; then
            ETCD_DEV="$dev"
            break 2
          fi
        fi
      done
      sleep 2
    done

    if [ -n "$ETCD_DEV" ]; then
      FSTYPE=$(lsblk -no FSTYPE "$ETCD_DEV" 2>/dev/null || true)
      [ -z "$FSTYPE" ] && sudo mkfs.ext4 -F "$ETCD_DEV"
      sudo mkdir -p /var/lib/etcd
      sudo mount -o noatime "$ETCD_DEV" /var/lib/etcd
      echo "$ETCD_DEV /var/lib/etcd ext4 defaults,noatime 0 0" >> /etc/fstab
      sudo chmod 0700 /var/lib/etcd
    else
      sudo mkdir -p /var/lib/etcd
      sudo chmod 0700 /var/lib/etcd
    fi

    /root/common-runtime.sh

    sed -i 's/PUBLIC_IP_ACCESS="false"/PUBLIC_IP_ACCESS="true"/' /root/master-runtime.sh
    sed -i 's/__BOOTSTRAP_TOKEN__/${local.kubeadm_token}/' /root/master-runtime.sh
    sed -i 's|__POD_CIDR__|${var.pod_subnet_cidr}|g' /root/master-runtime.sh
    sed -i 's|__POD_SUBNET_ID__|${aws_subnet.pods.id}|g' /root/master-runtime.sh

    /root/master-runtime.sh

    mkdir -p /home/ubuntu/.kube
    cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube
    chmod 600 /home/ubuntu/.kube/config

    echo "User Data Complete."
  USERDATA
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

  # Dedicated 10GB EBS for etcd — isolates etcd I/O from image pulls
  ebs_block_device {
    device_name           = "/dev/xvdf"
    volume_size           = 10
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data_base64 = base64gzip(local.master_userdata)

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
