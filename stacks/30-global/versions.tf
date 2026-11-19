terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.60" }
  }
  backend "s3" {}
}

# Global Accelerator is a global service whose API lives in us-west-2.
provider "aws" {
  region = "us-west-2"
  default_tags { tags = { project = "eks-multiregion", stack = "30-global", environment = var.environment, managed_by = "terraform" } }
}
