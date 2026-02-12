terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "ssh_pub_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

# --- Data Lookups ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "ubuntu_24" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# --- Infrastructure ---
resource "aws_key_pair" "mgmt_key" {
  key_name   = "mgmt-station-docker-v2"
  public_key = file(var.ssh_pub_key_path)
}

resource "aws_security_group" "mgmt_sg" {
  name   = "vscode-docker-sg-v2"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- EC2 Instance ---
resource "aws_instance" "vscode_server" {
  ami                         = data.aws_ami.ubuntu_24.id
  instance_type               = "t3.medium"
  vpc_security_group_ids      = [aws_security_group.mgmt_sg.id]
  subnet_id                   = data.aws_subnets.default.ids[0]
  key_name                    = aws_key_pair.mgmt_key.key_name
  associate_public_ip_address = true 

  user_data = <<-EOF
              #!/bin/bash
              # 1. Install Docker
              curl -fsSL https://get.docker.com -o get-docker.sh
              sh get-docker.sh

              # 2. Start Code-Server Container
              docker run -d --name code-server \
                -p 8080:8080 \
                -v "/home/ubuntu:/home/coder/project" \
                codercom/code-server:latest --auth none
              EOF

  tags = {
    Name = "VSCode-Docker-Station"
  }
}

# --- Wait Logic ---
resource "null_resource" "wait_for_vscode" {
  depends_on = [aws_instance.vscode_server]

  provisioner "local-exec" {
    command = "until curl -s --connect-timeout 2 http://${aws_instance.vscode_server.public_ip}:8080 > /dev/null; do echo 'Waiting...'; sleep 10; done"
  }
}

output "vscode_url" {
  value = "http://${aws_instance.vscode_server.public_ip}:8080"
}