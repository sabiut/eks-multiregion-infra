# Bootstrap: what must exist before the pipelines can run. Applied once, from a laptop.
#
#   state_bucket   where every stack keeps its Terraform state
#   images         the application's image repository, one copy per region
#   ci roles       the IAM roles GitHub Actions assumes (github.tf)

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# One object per stack per region: <region>/<stack>.tfstate. Locking uses S3 lock files
# (use_lockfile), so there is no DynamoDB table.
module "state_bucket" {
  source = "../modules/private-bucket"

  name          = "eks-multiregion-tfstate-${local.account_id}"
  sse_algorithm = "aws:kms"
}

module "images" {
  source   = "../modules/image-repository"
  for_each = toset(var.image_repositories)

  name    = each.value
  regions = var.regions
}
