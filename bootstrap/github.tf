# The three roles GitHub Actions signs in to with OIDC. Each call differs in two things:
# who may assume the role (subjects) and what the role may do (policies).
#
# The OIDC provider is one per account and already exists here, so it is looked up, not
# created. In a new account, create it first:
#   aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
#     --client-id-list sts.amazonaws.com

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# plan: pull requests and main may plan. Read everything, write only Terraform lock files.
module "plan_role" {
  source = "../modules/github-oidc-role"

  name              = "eks-multiregion-plan"
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects = [
    "repo:${var.infra_repo}:pull_request",
    "repo:${var.infra_repo}:ref:refs/heads/main",
  ]

  managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  inline_policy = [{
    Effect   = "Allow"
    Action   = ["s3:PutObject", "s3:DeleteObject"]
    Resource = "${module.state_bucket.arn}/*.tflock"
  }]
}

# apply: only jobs in the "production" environment, which requires a reviewer. The
# permissions are broad on purpose, because it creates VPCs, clusters and IAM roles. The
# guard is the trust policy (approved environment only), not the permissions.
module "apply_role" {
  source = "../modules/github-oidc-role"

  name              = "eks-multiregion-apply"
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects          = ["repo:${var.infra_repo}:environment:production"]

  managed_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

# publish: only the main branch of the application repository. Push images to the demo repositories
# in each region, nothing else.
module "publish_role" {
  source = "../modules/github-oidc-role"

  name              = "eks-multiregion-publish"
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects          = ["repo:${var.apps_repo}:ref:refs/heads/main"]

  inline_policy = [
    { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
    {
      Effect = "Allow"
      Action = [
        "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      ]
      Resource = flatten([for m in module.images : m.arns])
    },
  ]
}
