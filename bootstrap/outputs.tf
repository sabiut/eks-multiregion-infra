output "state_bucket" {
  value = module.state_bucket.name
}

# Set these as repository secrets (Settings > Secrets and variables > Actions). They are not
# passwords, but they contain the account ID, and secrets are masked in public workflow logs.
output "github_secrets" {
  value = {
    infra_repo = {
      AWS_PLAN_ROLE_ARN  = module.plan_role.arn
      AWS_APPLY_ROLE_ARN = module.apply_role.arn
      TF_STATE_BUCKET    = module.state_bucket.name
    }
    apps_repo = {
      AWS_PUBLISH_ROLE_ARN = module.publish_role.arn
    }
  }
}
