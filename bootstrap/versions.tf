# The bootstrap runs once from a laptop and keeps its state locally (ignored by Git), so the
# state bucket it creates can hold everything else.
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.60" }
  }
}

provider "aws" {
  region = var.state_region
  default_tags { tags = { project = "eks-multiregion", stack = "bootstrap", managed_by = "terraform" } }
}
