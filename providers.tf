terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    #    cloudflare = {
    #      source  = "cloudflare/cloudflare"
    #      version = "~> 4.0"
    #    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project = "k8s-cluster"
      Owner   = "terraform"
    }
  }
}

# provider "cloudflare" {
#   api_token = var.cloudflare_api_token
# }
