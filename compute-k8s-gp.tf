# General purpose k8s worker nodes (EKS self-managed)
resource "aws_launch_template" "k8s_worker_node" {
  name_prefix   = "${var.cluster_name}-gp-"
  image_id      = data.aws_ami.golden.id
  instance_type = var.gp_worker_instance_type
  key_name      = aws_key_pair.k8s_key.key_name

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker_sg.id, aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
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
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(<<-BASH
              #!/bin/bash
              set -ex
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

              echo "${base64encode(file("${path.module}/scripts/common-runtime.sh"))}" | base64 -d > /root/common-runtime.sh
              echo "${base64encode(file("${path.module}/scripts/worker-eks-bootstrap.sh"))}" | base64 -d > /root/worker-eks-bootstrap.sh
              chmod +x /root/common-runtime.sh /root/worker-eks-bootstrap.sh

              /root/common-runtime.sh

              sudo mkdir -p /var/openebs/local/postgres-data
              sudo mkdir -p /var/openebs/local/airflow-shared

              if [ -d "/mnt/spark-nvme" ]; then
                sudo mkdir -p /mnt/spark-nvme/starrocks-fe
                sudo mkdir -p /mnt/spark-nvme/starrocks-be
              fi

              sed -i 's|__CLUSTER_NAME__|${var.cluster_name}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__AWS_REGION__|${var.aws_region}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__NODE_NAME__|k8s-gp-node|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__EKS_ENDPOINT__|${aws_eks_cluster.main.endpoint}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__EKS_CA_DATA__|${aws_eks_cluster.main.certificate_authority[0].data}|g' /root/worker-eks-bootstrap.sh
              sed -i 's|__CLUSTER_DNS__|${cidrhost(aws_eks_cluster.main.kubernetes_network_config[0].service_ipv4_cidr, 10)}|g' /root/worker-eks-bootstrap.sh

              /root/worker-eks-bootstrap.sh
              BASH
  )
  tag_specifications {
    resource_type = "instance"
    tags = {
      Project                                     = var.cluster_name
      Name                                        = "k8s-gp-node"
      Role                                        = "k8s-gp-node"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "k8s_worker_node" {
  name                = "${var.cluster_name}-gp-asg"
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
    value               = "k8s-gp-node"
    propagate_at_launch = true
  }
  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
  depends_on = [aws_eks_cluster.main, aws_eks_access_entry.nodes]
}
