resource "aws_security_group" "master_sg" {
  name        = "k8s-master-sg"
  description = "Security group for K8s Master"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "k8s-master-sg"
  }
}

resource "aws_security_group" "worker_sg" {
  name        = "k8s-worker-sg"
  description = "Security group for K8s Workers"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "k8s-worker-sg"
  }
}

# --- Master Rules ---

resource "aws_security_group_rule" "master_ssh_ingress" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
  description       = "SSH from anywhere"
}

resource "aws_security_group_rule" "master_api_ingress" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
  description       = "K8s API Server"
}

resource "aws_security_group_rule" "master_internal_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.master_sg.id
  description       = "Internal Master Traffic"
}

resource "aws_security_group_rule" "master_internal_ingress_workers" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.worker_sg.id
  security_group_id        = aws_security_group.master_sg.id
  description              = "Traffic from Workers"
}

resource "aws_security_group_rule" "master_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
}

# --- Worker Rules ---

resource "aws_security_group_rule" "worker_ssh_ingress_master" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.master_sg.id
  security_group_id        = aws_security_group.worker_sg.id
  description              = "SSH from Master"
}

resource "aws_security_group_rule" "worker_internal_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
}

resource "aws_security_group_rule" "worker_internal_ingress_master" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.master_sg.id
  security_group_id        = aws_security_group.worker_sg.id
  description              = "Traffic from Master"
}



# Allow SSH from VPC as backup/direct access via VPN if ever needed (optional but good for debugging internally)
resource "aws_security_group_rule" "worker_ssh_ingress_vpc" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.worker_sg.id
}

resource "aws_security_group_rule" "worker_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker_sg.id
}

# Master: Allow HTTP
resource "aws_security_group_rule" "master_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
  description       = "HTTP from anywhere"
}

# Master: Allow HTTPS
resource "aws_security_group_rule" "master_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
  description       = "HTTPS from anywhere"
}

# Worker: Allow HTTP
resource "aws_security_group_rule" "worker_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker_sg.id
  description       = "HTTP from anywhere"
}

# Worker: Allow HTTPS
resource "aws_security_group_rule" "worker_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker_sg.id
  description       = "HTTPS from anywhere"
}

# --- Explicit Kubeadm & Cilium Required Ports ---
# Kubelet API
resource "aws_security_group_rule" "worker_kubelet_ingress" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.master_sg.id
  security_group_id        = aws_security_group.worker_sg.id
  description              = "Kubelet API from Master"
}

# Cilium BGP (Native Routing)
resource "aws_security_group_rule" "worker_bgp_ingress" {
  type              = "ingress"
  from_port         = 179
  to_port           = 179
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
  description       = "Cilium BGP from other workers"
}

resource "aws_security_group_rule" "master_bgp_ingress" {
  type                     = "ingress"
  from_port                = 179
  to_port                  = 179
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker_sg.id
  security_group_id        = aws_security_group.master_sg.id
  description              = "Cilium BGP from workers"
}

# Cilium Health
resource "aws_security_group_rule" "worker_cilium_health" {
  type              = "ingress"
  from_port         = 4240
  to_port           = 4240
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
  description       = "Cilium Health Checks"
}
