data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

data "aws_ami" "golden" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["k8s-ubuntu-2404-arm64-golden-v1-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
