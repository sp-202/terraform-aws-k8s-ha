resource "aws_security_group" "master_sg" {
  name        = "${var.cluster_name}-master-sg"
  description = "Security group for K8s Master"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-master-sg"
  }
}

resource "aws_security_group" "worker_sg" {
  name        = "${var.cluster_name}-worker-sg"
  description = "Security group for K8s Workers"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-worker-sg"
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

# Pods run on secondary ENI (pod subnet) — AWS sees source IP as 10.0.4.x
# not the worker node SG, so we need an explicit CIDR rule
resource "aws_security_group_rule" "master_ingress_pod_subnet" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.pod_subnet_cidr]
  security_group_id = aws_security_group.master_sg.id
  description       = "All traffic from pod subnet (Cilium ENI secondary IPs)"
}

resource "aws_security_group_rule" "master_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
}

resource "aws_security_group_rule" "master_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
  description       = "HTTP from anywhere"
}

resource "aws_security_group_rule" "master_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.master_sg.id
  description       = "HTTPS from anywhere"
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

resource "aws_security_group_rule" "master_cilium_health_from_workers" {
  type                     = "ingress"
  from_port                = 4240
  to_port                  = 4240
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker_sg.id
  security_group_id        = aws_security_group.master_sg.id
  description              = "Cilium Health from workers"
}

resource "aws_security_group_rule" "master_cilium_health_from_pod_subnet" {
  type              = "ingress"
  from_port         = 4240
  to_port           = 4240
  protocol          = "tcp"
  cidr_blocks       = [var.pod_subnet_cidr]
  security_group_id = aws_security_group.master_sg.id
  description       = "Cilium Health from pod subnet"
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

resource "aws_security_group_rule" "worker_ssh_ingress_vpc" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.worker_sg.id
  description       = "SSH from VPC"
}

resource "aws_security_group_rule" "worker_internal_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
  description       = "Internal worker to worker traffic"
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

# Pods on secondary ENI — source IP is 10.0.4.x not the worker SG
resource "aws_security_group_rule" "worker_ingress_pod_subnet" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.pod_subnet_cidr]
  security_group_id = aws_security_group.worker_sg.id
  description       = "All traffic from pod subnet (Cilium ENI secondary IPs)"
}

resource "aws_security_group_rule" "worker_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker_sg.id
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

resource "aws_security_group_rule" "worker_kubelet_ingress" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.master_sg.id
  security_group_id        = aws_security_group.worker_sg.id
  description              = "Kubelet API from Master"
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