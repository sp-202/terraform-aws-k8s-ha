resource "aws_key_pair" "k8s_key" {
  key_name   = "k8s-access-key"
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
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.master_instance_type
  subnet_id     = aws_subnet.public.id
  key_name      = aws_key_pair.k8s_key.key_name

  vpc_security_group_ids = [aws_security_group.master_sg.id]
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

              echo "${base64encode(file("${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              echo "${base64encode(file("${path.module}/scripts/master.sh"))}" | base64 -d > /root/master.sh

              chmod +x /root/common.sh /root/master.sh

              # Run common.sh
              /root/common.sh

              # Modify master.sh
              sed -i 's/PUBLIC_IP_ACCESS="false"/PUBLIC_IP_ACCESS="true"/' /root/master.sh
              sed -i 's/sudo kubeadm init /sudo kubeadm init --token "${local.kubeadm_token}" /' /root/master.sh

              # Run master.sh
              /root/master.sh

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
    Name = "k8s-master"
    Role = "master"
  }
}


resource "aws_launch_template" "worker" {
  name_prefix   = "k8s-worker-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.k8s_key.key_name

  # Worker 80GB EBS Root Volume
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 80
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker_sg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Starting Worker User Data..."

              # Fetch Instance ID for Unique Naming
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

              echo "${base64encode(file("${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              chmod +x /root/common.sh
              
              /root/common.sh

              # Wait for master to be ready
              sleep 60
              
              echo "Installing AWS CLI v2 for modifying instance attributes..."
              if [ "$(uname -m)" = "aarch64" ]; then
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
              else
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              fi
              unzip -q awscliv2.zip
              sudo ./aws/install
              rm -rf awscliv2.zip aws/

              echo "Disabling Source/Dest Check for Cilium..."
              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region ${var.aws_region}
              
              echo "Joining Cluster..."
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k8s-worker-spark-$INSTANCE_ID
              
              echo "Worker User Data Complete."
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = "k8s-cluster"
      Name    = "k8s-worker-asg"
      Role    = "worker-spark"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# k8s spark worker nodes
resource "aws_autoscaling_group" "workers" {
  name                = "k8s-workers-asg"
  desired_capacity    = var.worker_count
  min_size            = var.worker_min
  max_size            = var.worker_max
  vpc_zone_identifier = [aws_subnet.private.id]

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker.id
        version            = "$Latest"
      }

      # User specifically requested Spot fleet to be primarily i4g.8xlarge
      override { instance_type = "i4g.8xlarge" }
      override { instance_type = "i4g.16xlarge" }  # Fallback massive storage
      override { instance_type = "im4gn.8xlarge" } # Fallback equivalent
    }

    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
    }
  }

  tag {
    key                 = "Name"
    value               = "k8s-worker-asg"
    propagate_at_launch = true
  }

  depends_on = [aws_instance.master]
}

# --- Dedicated k8s Storage Workers ---
resource "aws_instance" "minio_worker" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "im4gn.8xlarge"
  subnet_id     = aws_subnet.private.id
  key_name      = aws_key_pair.k8s_key.key_name

  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  source_dest_check      = false
  iam_instance_profile   = aws_iam_instance_profile.node_profile.name

  root_block_device {
    volume_size           = 80
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Starting MinIO Dedicated Worker User Data..."
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

              echo "${base64encode(file("${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              chmod +x /root/common.sh
              
              /root/common.sh

              sleep 60

              echo "Installing AWS CLI v2 for modifying instance attributes..."
              if [ "$(uname -m)" = "aarch64" ]; then
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
              else
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              fi
              unzip -q awscliv2.zip
              sudo ./aws/install
              rm -rf awscliv2.zip aws/

              echo "Disabling Source/Dest Check for Cilium..."
              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region ${var.aws_region}
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k8s-worker-minio-$INSTANCE_ID
              EOF
  )

  tags = {
    Name = "k8s-worker-minio-dedicated"
    Role = "worker-storage"
  }
}

# Dedicated spark critical driver/worker nodes
resource "aws_instance" "worker-spark-critical" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "i4g.8xlarge"
  subnet_id     = aws_subnet.private.id
  key_name      = aws_key_pair.k8s_key.key_name

  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  source_dest_check      = false
  iam_instance_profile   = aws_iam_instance_profile.node_profile.name

  root_block_device {
    volume_size           = 80
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Starting i4g Dedicated Worker User Data..."
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

              echo "${base64encode(file("${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              chmod +x /root/common.sh
              
              /root/common.sh

              sleep 60

              echo "Installing AWS CLI v2 for modifying instance attributes..."
              if [ "$(uname -m)" = "aarch64" ]; then
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
              else
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              fi
              unzip -q awscliv2.zip
              sudo ./aws/install
              rm -rf awscliv2.zip aws/

              echo "Disabling Source/Dest Check for Cilium..."
              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region ${var.aws_region}
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k8s-worker-spark-critical-$INSTANCE_ID
              EOF
  )

  tags = {
    Name = "k8s-worker-spark-critical"
    Role = "worker-spark-critical"
  }
}

# General purpose k8s worker nodes
resource "aws_instance" "k8s_worker_node" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "im4gn.4xlarge"
  subnet_id     = aws_subnet.private.id
  key_name      = aws_key_pair.k8s_key.key_name

  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  source_dest_check      = false
  iam_instance_profile   = aws_iam_instance_profile.node_profile.name

  root_block_device {
    volume_size           = 80
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Starting im4gn Dedicated Worker User Data..."
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

              echo "${base64encode(file("${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              chmod +x /root/common.sh
              
              /root/common.sh

              sleep 60

              echo "Installing AWS CLI v2 for modifying instance attributes..."
              if [ "$(uname -m)" = "aarch64" ]; then
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
              else
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              fi
              unzip -q awscliv2.zip
              sudo ./aws/install
              rm -rf awscliv2.zip aws/

              echo "Disabling Source/Dest Check for Cilium..."
              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region ${var.aws_region}
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k8s-worker-node-$INSTANCE_ID
              EOF
  )

  tags = {
    Name = "k8s-worker-node"
    Role = "k8s-worker-node"
  }
}
