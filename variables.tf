variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "default"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_subnet_cidr_2" {
  description = "CIDR block for the second private subnet"
  type        = string
  default     = "10.0.3.0/24"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to be used for instances"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "master_instance_type" {
  description = "Instance type for the K3s master node"
  type        = string
  default     = "c5.2xlarge" # 8 vCPU, 16 GiB RAM
}

variable "worker_instance_type" {
  description = "Instance type for the K3s worker nodes"
  type        = string
  default     = "r5.2xlarge" # 8 vCPU, 64 GiB RAM
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}
