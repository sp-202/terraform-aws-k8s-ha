resource "aws_launch_template" "worker" {
  name_prefix   = "${var.cluster_name}-worker-lt-"
  image_id      = data.aws_ami.golden.id
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

              echo "${base64encode(file("${path.module}/scripts/common-runtime.sh"))}" | base64 -d > /root/common-runtime.sh
              chmod +x /root/common-runtime.sh
              
              /root/common-runtime.sh

              # Wait for master to be ready
              sleep 60
              


              echo "Disabling Source/Dest Check for Cilium..."
              aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --no-source-dest-check --region ${var.aws_region}
              
              echo "Joining Cluster..."
              MAX_RETRIES=3
              RETRY_COUNT=0
              JOIN_SUCCESS=false

              while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                  echo "Attempting to join cluster (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
                  if sudo kubeadm join ${aws_instance.master.private_ip}:6443 --token ${local.kubeadm_token} --discovery-token-unsafe-skip-ca-verification --node-name spark-worker-$INSTANCE_ID; then
                      JOIN_SUCCESS=true
                      break
                  fi
                  RETRY_COUNT=$((RETRY_COUNT+1))
                  echo "Join failed. Retrying in 30 seconds..."
                  sleep 30
              done

              if [ "$JOIN_SUCCESS" = false ]; then
                  echo "Failed to join cluster after $MAX_RETRIES attempts. Terminating instance for auto-remediation..."
                  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region ${var.aws_region}
                  exit 1
              fi
              
              echo "Worker User Data Complete."
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = var.cluster_name
      Name    = "spark-worker"
      Role    = "spark-worker"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# k8s spark worker nodes
resource "aws_autoscaling_group" "workers" {
  name                = "${var.cluster_name}-workers-asg"
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
    value               = "spark-worker"
    propagate_at_launch = true
  }

  depends_on = [aws_instance.master]
}
