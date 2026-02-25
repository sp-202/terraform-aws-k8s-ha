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


variable "ssh_public_key_path" {
  description = "Path to the SSH public key to be used for instances"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "master_instance_type" {
  description = "Instance type for the K8s master node"
  type        = string
  default     = "c7g.2xlarge" # 8 vCPU, 16 GiB RAM
}

variable "worker_instance_type" {
  description = "Instance type for the K8s worker nodes"
  type        = string
  default     = "i4g.8xlarge" # 32 vCPU, 256 GiB RAM, 7.5TB NVMe
}

variable "worker_count" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count == 3
    error_message = "The desired worker_count MUST be exactly 3."
  }
}

variable "pod_cidr" {
  description = "Secondary CIDR block for Kubernetes Pods"
  type        = string
  default     = "10.244.0.0/16"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "k8s-ha-cluster"
}

variable "availability_zone" {
  description = "AV Zone for deployment"
  type        = string
  default     = "us-east-1a"
}

variable "worker_min" {
  description = "Strict minimum workers"
  type        = number
  default     = 3

  validation {
    condition     = var.worker_min == 3
    error_message = "The worker_min MUST be exactly 3."
  }
}

variable "worker_max" {
  description = "Strict maximum workers"
  type        = number
  default     = 4

  validation {
    condition     = var.worker_max == 4
    error_message = "The worker_max MUST be exactly 4."
  }
}

# variable "cloudflare_api_token" {
#   description = "Cloudflare API Token with DNS:Edit permissions"
#   type        = string
#   sensitive   = true
# }
# 
# variable "cloudflare_zone_id" {
#   description = "Cloudflare Zone ID for the domain"
#   type        = string
# }
# 
# variable "domain_name" {
#   description = "The root domain name (e.g. example.com)"
#   type        = string
# }
