# fck-nat — single t4g.micro instance replacing AWS NAT Gateway (~$3/mo vs ~$32/mo)
# The fck-nat AMI (Amazon Linux 2023) ships with ip_forward + iptables MASQUERADE
# pre-configured. No user-data needed — it works out of the box.
#
# Production design notes:
# - source_dest_check=false is set on the instance so AWS does not drop forwarded
#   packets whose source/destination doesn't match the instance's own IPs.
# - A CloudWatch recovery alarm restarts the instance on underlying host failure.
#   Recovery preserves the ENI ID and therefore the route table entry stays valid.
# - The EIP is associated to the instance. On a recovery action AWS preserves the
#   primary ENI, so the EIP and route table entry remain stable.
# - Instance replacement via `terraform apply` (e.g. AMI update) will produce a new
#   primary_network_interface_id. Run `terraform apply` to refresh the route table.

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
  instance_type               = "t4g.small"
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

# CloudWatch recovery alarm — automatically recovers the instance on underlying
# host failure. EC2 recovery preserves the primary ENI ID, so the route table
# entry (which references primary_network_interface_id) stays valid with no
# manual intervention.
resource "aws_cloudwatch_metric_alarm" "nat_recovery" {
  alarm_name          = "${var.cluster_name}-nat-recovery"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.nat.id }
  period              = 60
  evaluation_periods  = 2
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:recover"]
  alarm_description   = "Recover fck-nat on host failure (preserves primary ENI and route table entry)"
}
