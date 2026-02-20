resource "aws_key_pair" "k3s_key" {
  key_name   = "k3s-access-key"
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

resource "aws_instance" "master" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.master_instance_type
  subnet_id     = aws_subnet.public.id
  key_name      = aws_key_pair.k3s_key.key_name

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
    Name = "k3s-master"
    Role = "master"
  }
}

resource "aws_launch_template" "worker" {
  name_prefix   = "k3s-worker-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.k3s_key.key_name

  # Worker 80GB EBS Root Volume
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 80
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker_sg.id]
    source_dest_check           = false
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
              
              echo "Joining Cluster..."
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k3s-worker-$INSTANCE_ID
              
              echo "Worker User Data Complete."
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = "k3s-cluster"
      Name    = "k3s-worker-asg"
      Role    = "worker"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "workers" {
  name                = "k3s-workers-asg"
  desired_capacity    = var.worker_count
  min_size            = var.worker_min
  max_size            = var.worker_max
  vpc_zone_identifier = [aws_subnet.private.id, aws_subnet.private_2.id]

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
    value               = "k3s-worker-asg"
    propagate_at_launch = true
  }

  depends_on = [aws_instance.master]
}

# --- Dedicated Storage Workers ---

resource "aws_instance" "minio_worker" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "i4g.16xlarge"
  subnet_id     = aws_subnet.private.id
  key_name      = aws_key_pair.k3s_key.key_name

  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  source_dest_check      = false

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
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k3s-worker-minio-$INSTANCE_ID
              EOF
  )

  tags = {
    Name = "k3s-worker-minio-dedicated"
    Role = "worker-storage"
  }
}

resource "aws_instance" "dedicated_i4g_worker" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "i4g.8xlarge"
  subnet_id     = aws_subnet.private_2.id
  key_name      = aws_key_pair.k3s_key.key_name

  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  source_dest_check      = false

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
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k3s-worker-i4g-$INSTANCE_ID
              EOF
  )

  tags = {
    Name = "k3s-worker-i4g-dedicated"
    Role = "worker-storage"
  }
}

resource "aws_instance" "dedicated_im4gn_worker" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "im4gn.4xlarge"
  subnet_id     = aws_subnet.private.id
  key_name      = aws_key_pair.k3s_key.key_name

  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  source_dest_check      = false

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
              sudo kubeadm join ${aws_instance.master.public_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k3s-worker-im4gn-$INSTANCE_ID
              EOF
  )

  tags = {
    Name = "k3s-worker-im4gn-dedicated"
    Role = "worker-storage"
  }
}
