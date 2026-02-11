resource "aws_security_group" "master_sg" {
  name        = "k3s-master-sg"
  description = "Security group for K3s Master"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "k3s-master-sg"
  }
}

resource "aws_security_group" "worker_sg" {
  name        = "k3s-worker-sg"
  description = "Security group for K3s Workers"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "k3s-worker-sg"
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
  description       = "K3s API Server"
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
