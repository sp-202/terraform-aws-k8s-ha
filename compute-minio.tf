resource "aws_launch_template" "minio_worker" {
  name_prefix   = "${var.cluster_name}-minio-"
  image_id      = data.aws_ami.golden.id
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

              echo "${base64encode(file("${path.module}/scripts/common-runtime.sh"))}" | base64 -d > /root/common-runtime.sh
              chmod +x /root/common-runtime.sh
              /root/common-runtime.sh
              
              if [ -d "/mnt/spark-nvme" ]; then
                sudo mkdir -p /mnt/spark-nvme/minio
              fi

              # Wait for master to be ready
              sleep 60

              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region ${var.aws_region}

              echo "Joining Cluster..."
              MAX_RETRIES=3
              RETRY_COUNT=0
              JOIN_SUCCESS=false

              while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                  if sudo kubeadm join ${aws_instance.master.private_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name minio-worker-$INSTANCE_ID; then
                      JOIN_SUCCESS=true
                      break
                  fi
                  RETRY_COUNT=$((RETRY_COUNT+1))
                  sleep 30
              done

              if [ "$JOIN_SUCCESS" = false ]; then
                  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region ${var.aws_region}
                  exit 1
              fi
              BASH
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = var.cluster_name
      Name    = "minio-worker"
      Role    = "minio-worker"
    }
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "minio_worker" {
  name                = "${var.cluster_name}-minio-asg"
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
    value               = "minio-worker"
    propagate_at_launch = true
  }
  depends_on = [aws_instance.master]
}
