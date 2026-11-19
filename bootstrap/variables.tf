variable "state_region" {
  description = "Region of the Terraform state bucket."
  type        = string
  default     = "ap-southeast-2"
}

variable "regions" {
  description = "Regions that get a cluster. Each one gets its own image repository."
  type        = list(string)
  default     = ["ap-southeast-2", "ap-southeast-1"]
}

variable "infra_repo" {
  description = "GitHub repository that runs Terraform and Ansible, as owner/name."
  type        = string
}

variable "apps_repo" {
  description = "GitHub repository that builds the application image, as owner/name."
  type        = string
}

variable "image_repositories" {
  description = "ECR repositories for the application: one per tier that runs in the cluster."
  type        = list(string)
  default     = ["demo-web", "demo-api"]
}

# GitHub puts the repository in the token's "sub" claim, and the roles' trust policies match
# on it. Repositories created since GitHub introduced immutable subjects send the owner and
# repository IDs as well ("repo:owner@123/name@456"), and a trust policy written for the
# classic form ("repo:owner/name") then refuses every sign-in. Find a repository's prefix with:
#   gh api repos/<owner>/<name>/actions/oidc/customization/sub --jq .sub_claim_prefix

variable "infra_sub_prefix" {
  description = "The infra repository's OIDC subject prefix. Empty = the classic repo:<owner>/<name>."
  type        = string
  default     = ""
}

variable "apps_sub_prefix" {
  description = "The application repository's OIDC subject prefix. Empty = the classic repo:<owner>/<name>."
  type        = string
  default     = ""
}
