import re

with open("compute.tf", "r") as f:
    content = f.read()

# Let's cleanly split at "# --- Dedicated k8s Storage Workers ---"
index = content.find("# --- Dedicated k8s Storage Workers ---")

if index == -1:
    print("Could not find the split point.")
    exit(1)

base_content = content[:index]

rest_content = """# --- Dedicated k8s Storage Workers ---
resource "aws_launch_template" "minio_worker" {
  name_prefix   = "k8s-minio-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "im4gn.8xlarge"
  key_name      = aws_key_pair.k8s_key.key_name

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker_sg.id]
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile.name
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 80
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-BASH
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Starting MinIO Dedicated Worker User Data..."
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

              echo "$${base64encode(file("$${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              chmod +x /root/common.sh
              /root/common.sh
              sleep 60

              if [ "$(uname -m)" = "aarch64" ]; then
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
              else
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              fi
              unzip -q awscliv2.zip
              sudo ./aws/install
              rm -rf awscliv2.zip aws/

              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region $${var.aws_region}

              MAX_RETRIES=3
              RETRY_COUNT=0
              JOIN_SUCCESS=false

              while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                  if sudo kubeadm join $${aws_instance.master.public_ip}:6443 --token $${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k8s-worker-minio-$INSTANCE_ID; then
                      JOIN_SUCCESS=true
                      break
                  fi
                  RETRY_COUNT=$((RETRY_COUNT+1))
                  sleep 30
              done

              if [ "$JOIN_SUCCESS" = false ]; then
                  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $${var.aws_region}
                  exit 1
              fi
              BASH
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = "k8s-cluster"
      Name    = "k8s-worker-minio-dedicated"
      Role    = "worker-storage"
    }
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "minio_worker" {
  name                = "k8s-minio-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = [aws_subnet.private.id]
  launch_template {
    id      = aws_launch_template.minio_worker.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "k8s-worker-minio-dedicated"
    propagate_at_launch = true
  }
  depends_on = [aws_instance.master]
}

# Dedicated spark critical driver/worker nodes
resource "aws_launch_template" "worker_spark_critical" {
  name_prefix   = "k8s-spark-critical-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "i4g.8xlarge"
  key_name      = aws_key_pair.k8s_key.key_name

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker_sg.id]
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile.name
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 80
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-BASH
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

              echo "$${base64encode(file("$${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              chmod +x /root/common.sh
              /root/common.sh
              sleep 60

              if [ "$(uname -m)" = "aarch64" ]; then
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
              else
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              fi
              unzip -q awscliv2.zip
              sudo ./aws/install
              rm -rf awscliv2.zip aws/

              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region $${var.aws_region}

              MAX_RETRIES=3
              RETRY_COUNT=0
              JOIN_SUCCESS=false

              while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                  if sudo kubeadm join $${aws_instance.master.public_ip}:6443 --token $${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k8s-worker-spark-critical-$INSTANCE_ID; then
                      JOIN_SUCCESS=true
                      break
                  fi
                  RETRY_COUNT=$((RETRY_COUNT+1))
                  sleep 30
              done

              if [ "$JOIN_SUCCESS" = false ]; then
                  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $${var.aws_region}
                  exit 1
              fi
              BASH
  )
  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = "k8s-cluster"
      Name    = "k8s-worker-spark-critical"
      Role    = "worker-spark-critical"
    }
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "worker_spark_critical" {
  name                = "k8s-spark-critical-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = [aws_subnet.private.id]
  launch_template {
    id      = aws_launch_template.worker_spark_critical.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "k8s-worker-spark-critical"
    propagate_at_launch = true
  }
  depends_on = [aws_instance.master]
}

# General purpose k8s worker nodes
resource "aws_launch_template" "k8s_worker_node" {
  name_prefix   = "k8s-general-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "im4gn.4xlarge"
  key_name      = aws_key_pair.k8s_key.key_name

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker_sg.id]
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile.name
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 80
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-BASH
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
              INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)

              echo "$${base64encode(file("$${path.module}/scripts/common.sh"))}" | base64 -d > /root/common.sh
              chmod +x /root/common.sh
              /root/common.sh
              sleep 60

              if [ "$(uname -m)" = "aarch64" ]; then
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
              else
                  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              fi
              unzip -q awscliv2.zip
              sudo ./aws/install
              rm -rf awscliv2.zip aws/

              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region $${var.aws_region}

              MAX_RETRIES=3
              RETRY_COUNT=0
              JOIN_SUCCESS=false

              while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                  if sudo kubeadm join $${aws_instance.master.public_ip}:6443 --token $${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name k8s-worker-node-$INSTANCE_ID; then
                      JOIN_SUCCESS=true
                      break
                  fi
                  RETRY_COUNT=$((RETRY_COUNT+1))
                  sleep 30
              done

              if [ "$JOIN_SUCCESS" = false ]; then
                  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $${var.aws_region}
                  exit 1
              fi
              BASH
  )
  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = "k8s-cluster"
      Name    = "k8s-worker-node"
      Role    = "k8s-worker-node"
    }
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "k8s_worker_node" {
  name                = "k8s-general-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = [aws_subnet.private.id]
  launch_template {
    id      = aws_launch_template.k8s_worker_node.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "k8s-worker-node"
    propagate_at_launch = true
  }
  depends_on = [aws_instance.master]
}
"""

with open("compute.tf", "w") as f:
    f.write(base_content + rest_content)

print("Updated compute.tf")
