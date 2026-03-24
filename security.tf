# -------------------------------------------------------
# Security Groups — EKS self-managed node setup
# master_sg is replaced by eks_cluster_sg (in eks.tf)
# -------------------------------------------------------

resource "aws_key_pair" "k8s_key" {
  key_name   = "${var.cluster_name}-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "worker_sg" {
  name        = "${var.cluster_name}-worker-sg"
  description = "Security group for K8s self-managed worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-worker-sg"
  }
}

# --- Worker Rules ---

# SSH from within VPC (bastion / ops access)
resource "aws_security_group_rule" "worker_ssh_ingress_vpc" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.worker_sg.id
  description       = "SSH from VPC"
}

# Workers talking to each other (all protocols — required for Cilium health + BGP)
resource "aws_security_group_rule" "worker_internal_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
  description       = "Worker to worker traffic"
}

# EKS control plane reaching kubelet API on workers (required for logs, exec, port-forward)
resource "aws_security_group_rule" "worker_kubelet_ingress_eks" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  security_group_id        = aws_security_group.worker_sg.id
  description              = "Kubelet API from EKS control plane"
}

# EKS control plane to worker — ephemeral port range (for kubectl exec / port-forward)
resource "aws_security_group_rule" "worker_ephemeral_ingress_eks" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  security_group_id        = aws_security_group.worker_sg.id
  description              = "Ephemeral ports from EKS control plane"
}

# Pods on secondary ENI — source IP is from pod subnet, not worker SG
resource "aws_security_group_rule" "worker_ingress_pod_subnet" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.pod_subnet_cidr]
  security_group_id = aws_security_group.worker_sg.id
  description       = "All traffic from pod subnet (Cilium ENI secondary IPs)"
}

resource "aws_security_group_rule" "worker_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker_sg.id
  description       = "HTTP from anywhere"
}

resource "aws_security_group_rule" "worker_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker_sg.id
  description       = "HTTPS from anywhere"
}

resource "aws_security_group_rule" "worker_bgp_ingress" {
  type              = "ingress"
  from_port         = 179
  to_port           = 179
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
  description       = "Cilium BGP from other workers"
}

resource "aws_security_group_rule" "worker_cilium_health" {
  type              = "ingress"
  from_port         = 4240
  to_port           = 4240
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
  description       = "Cilium Health between workers"
}

resource "aws_security_group_rule" "worker_cilium_health_from_pod_subnet" {
  type              = "ingress"
  from_port         = 4240
  to_port           = 4240
  protocol          = "tcp"
  cidr_blocks       = [var.pod_subnet_cidr]
  security_group_id = aws_security_group.worker_sg.id
  description       = "Cilium Health from pod subnet"
}

# # Cloudflare Tunnel QUIC (UDP/7844) — loss-tolerant protocol prevents Error 1033 on packet loss
# resource "aws_security_group_rule" "worker_cloudflare_tunnel_quic" {
#   type              = "egress"
#   from_port         = 7844
#   to_port           = 7844
#   protocol          = "udp"
#   cidr_blocks       = ["0.0.0.0/0"]
#   security_group_id = aws_security_group.worker_sg.id
#   description       = "Cloudflare Tunnel QUIC protocol (UDP/7844)"
# }

resource "aws_security_group_rule" "worker_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker_sg.id
}

# Allow EKS control plane to receive connections from workers (HTTPS/443)
resource "aws_security_group_rule" "eks_cluster_ingress_pod_subnet" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.pod_subnet_cidr]
  security_group_id = aws_security_group.eks_cluster_sg.id
  description       = "EKS API from pod subnet (Cilium ENI secondary IPs)"
}
