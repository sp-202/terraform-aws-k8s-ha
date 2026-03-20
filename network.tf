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
    Name                                            = "${var.cluster_name}-public-subnet"
    "cilium.io/no-eni-allocation"                   = "true"
    "kubernetes.io/cluster/${var.cluster_name}"     = "owned"
    "kubernetes.io/role/elb"                        = "1"
  }
}

# Private Subnet — worker nodes run here
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name                                            = "${var.cluster_name}-private-subnet-1"
    "cilium.io/no-eni-allocation"                   = "true"
    "kubernetes.io/cluster/${var.cluster_name}"     = "owned"
    "kubernetes.io/role/internal-elb"               = "1"
  }
}

# Pod Subnet — Cilium ENI secondary IPs allocated here
resource "aws_subnet" "pods" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.pod_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name                                            = "${var.cluster_name}-pod-subnet"
    "kubernetes.io/cluster/${var.cluster_name}"     = "owned"
    "kubernetes.io/role/internal-elb"               = "1"
    "cilium-pod-subnet"                             = "1"
  }
}


# NAT Gateway (for Private Subnet internet access)
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "k8s-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "k8s-nat-gw"
  }

  depends_on = [aws_internet_gateway.main]
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
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
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

