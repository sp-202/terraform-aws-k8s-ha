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

  user_data = <<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

              echo "Starting Master User Data..."

              echo "${base64encode(file("${path.module}/scripts/common-runtime.sh"))}" | base64 -d > /root/common-runtime.sh
              echo "${base64encode(file("${path.module}/scripts/master-runtime.sh"))}" | base64 -d > /root/master-runtime.sh

              chmod +x /root/common-runtime.sh /root/master-runtime.sh

              # Run common-runtime.sh
              /root/common-runtime.sh

              # Modify master-runtime.sh
              sed -i 's/PUBLIC_IP_ACCESS="false"/PUBLIC_IP_ACCESS="true"/' /root/master-runtime.sh
              sed -i 's/sudo kubeadm init /sudo kubeadm init --token "${local.kubeadm_token}" /' /root/master-runtime.sh

              # Run master-runtime.sh
              /root/master-runtime.sh

              # Untaint master to allow scheduling pods
              export KUBECONFIG=/etc/kubernetes/admin.conf
              kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true

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
