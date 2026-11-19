# One ECR repository of the same name in each region, so each cluster pulls from its own
# region and a regional outage does not block image pulls in the other. The apps pipeline
# pushes the same tag to both.
# (Registry replication would also work, but it is one account-wide setting, and this
# account already uses it for another project.)

resource "aws_ecr_repository" "this" {
  for_each = toset(var.regions)
  region   = each.value

  name = var.name
  # A tag can never be reused for a different image: what was tested is what runs.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  region     = each.key
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${var.keep_images} images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.keep_images }
      action       = { type = "expire" }
    }]
  })
}
