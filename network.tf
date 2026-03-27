# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                        = "k8s-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}



# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "k8s-igw"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-subnet"
    "cilium.io/no-eni-allocation"               = "true"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# Private Subnet — worker nodes run here
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name                                        = "${var.cluster_name}-private-subnet-1"
    "cilium.io/no-eni-allocation"               = "true"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# Pod Subnet — Cilium ENI secondary IPs allocated here
resource "aws_subnet" "pods" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.pod_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name                                        = "${var.cluster_name}-pod-subnet"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"           = "1"
    "cilium-pod-subnet"                         = "1"
  }
}


# EKS control-plane subnets — one per AZ in the region, no workers run here.
# EKS requires subnets in ≥2 AZs; this block satisfies that automatically
# regardless of how many AZs us-east-1 has.
locals {
  eks_cp_azs = data.aws_availability_zones.available.names
}

resource "aws_subnet" "eks_cp" {
  for_each = toset(local.eks_cp_azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.eks_cp_subnet_base_cidr, 4, index(local.eks_cp_azs, each.key))
  availability_zone = each.key

  tags = {
    Name                                        = "${var.cluster_name}-eks-cp-${each.key}"
    "cilium.io/no-eni-allocation"               = "true"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

resource "aws_route_table_association" "eks_cp" {
  for_each = aws_subnet.eks_cp

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "k8s-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Route Table for Private Subnet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }

  tags = {
    Name = "k8s-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "pods" {
  subnet_id      = aws_subnet.pods.id
  route_table_id = aws_route_table.private.id
}

