# fck-nat — single t4g.nano instance replacing AWS NAT Gateway (~$3/mo vs ~$32/mo)
# The fck-nat AMI (Amazon Linux 2023) ships with ip_forward + iptables MASQUERADE
# pre-configured. No user-data needed — it works out of the box.

data "aws_ami" "fck_nat" {
  most_recent = true

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-ebs"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  owners = ["568608671756"]
}

resource "aws_security_group" "nat" {
  name        = "${var.cluster_name}-nat-sg"
  description = "fck-nat instance allows all VPC traffic to be NATed"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-nat-sg"
  }
}

resource "aws_security_group_rule" "nat_ingress_vpc" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.nat.id
  description       = "All traffic from VPC (workers, pods, EKS CP ENIs)"
}

resource "aws_security_group_rule" "nat_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nat.id
  description       = "Outbound internet"
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

resource "aws_instance" "nat" {
  ami                         = data.aws_ami.fck_nat.id
  instance_type               = "t4g.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nat.id]
  source_dest_check           = false
  associate_public_ip_address = true

  tags = {
    Name    = "${var.cluster_name}-fck-nat"
    Project = var.cluster_name
    Role    = "nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip_association" "nat" {
  instance_id   = aws_instance.nat.id
  allocation_id = aws_eip.nat.id
}
