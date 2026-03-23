# Spark spot worker nodes (EKS self-managed)
resource "aws_launch_template" "worker" {
  name_prefix   = "${var.cluster_name}-worker-lt-"
  image_id      = data.aws_ami.golden.id
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.k8s_key.key_name

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
    security_groups             = [aws_security_group.worker_sg.id, aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64gzip(<<-EOF
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

              echo "Starting Spark Spot Worker User Data..."

              echo "${base64encode(file("${path.module}/scripts/common-runtime.sh"))}" | base64 -d > /root/common-runtime.sh
              echo "${base64encode(file("${path.module}/scripts/worker-eks-bootstrap.sh"))}" | base64 -d > /root/worker-eks-bootstrap.sh
              chmod +x /root/common-runtime.sh /root/worker-eks-bootstrap.sh

              /root/common-runtime.sh

              sed -i 's|__CLUSTER_NAME__|${var.cluster_name}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__AWS_REGION__|${var.aws_region}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__NODE_NAME__|spark-worker|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__EKS_ENDPOINT__|${aws_eks_cluster.main.endpoint}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__EKS_CA_DATA__|${aws_eks_cluster.main.certificate_authority[0].data}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__CLUSTER_DNS__|${cidrhost(aws_eks_cluster.main.kubernetes_network_config[0].service_ipv4_cidr, 10)}|g' /root/worker-eks-bootstrap.sh

              /root/worker-eks-bootstrap.sh

              echo "Spark Spot Worker User Data Complete."
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Project                                     = var.cluster_name
      Name                                        = "spark-worker"
      Role                                        = "spark-worker"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
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

      dynamic "override" {
        for_each = var.spot_overrides
        content {
          instance_type = override.value
        }
      }
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
  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  depends_on = [aws_eks_cluster.main, aws_eks_access_entry.nodes, aws_route_table_association.private]
}
