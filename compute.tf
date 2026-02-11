resource "aws_key_pair" "k3s_key" {
  key_name   = "k3s-access-key"
  public_key = file(var.ssh_public_key_path)
}

resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

resource "aws_instance" "master" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.master_instance_type
  subnet_id     = aws_subnet.public.id
  key_name      = aws_key_pair.k3s_key.key_name

  vpc_security_group_ids = [aws_security_group.master_sg.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

              echo "Starting User Data..."
              
              apt-get update
              DEBIAN_FRONTEND=noninteractive apt-get install -y curl

              # Fetch Public IP using IMDSv2 (requires curl)
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)
              
              echo "Detected Public IP: $PUBLIC_IP"

              echo "Installing K3s..."
              curl -sfL https://get.k3s.io | K3S_TOKEN=${random_password.k3s_token.result} sh -s - server --cluster-init --tls-san $PUBLIC_IP
              
              # Wait for k3s to be ready
              until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 2; done
              
              # Copy config for ubuntu user
              mkdir -p /home/ubuntu/.kube
              cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
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

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker_sg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Starting Worker User Data..."

              # Wait for master to be ready
              sleep 60
              
              apt-get update
              DEBIAN_FRONTEND=noninteractive apt-get install -y curl

              echo "Joining Cluster..."
              curl -sfL https://get.k3s.io | K3S_URL=https://${aws_instance.master.private_ip}:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -
              
              echo "Worker User Data Complete."
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = "k3s-cluster"
      Name    = "k3s-worker-asg" # This tag will be propagated to instances
      Role    = "worker"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "workers" {
  name             = "k3s-workers-asg"
  desired_capacity = var.worker_count
  min_size         = var.worker_count
  max_size         = var.worker_count
  # Updated to use both private subnets
  vpc_zone_identifier = [aws_subnet.private.id, aws_subnet.private_2.id]

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker.id
        version            = "$Latest"
      }

      # List of acceptable instance types for Spot
      override {
        instance_type = "r5.2xlarge"
      }
      override {
        instance_type = "r5d.2xlarge"
      }
      override {
        instance_type = "r5a.2xlarge"
      }
      override {
        instance_type = "r4.2xlarge"
      }
      override {
        instance_type = "m5.2xlarge" # Fallback if memory optimized are all out, though user asked for 64GB...
      }
    }

    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0 # 100% Spot Instances
      spot_allocation_strategy                 = "price-capacity-optimized"
    }
  }

  tag {
    key                 = "Name"
    value               = "k3s-worker-asg"
    propagate_at_launch = true
  }

  # Ensure we wait for master to be fully up before launching workers
  depends_on = [aws_instance.master]
}
