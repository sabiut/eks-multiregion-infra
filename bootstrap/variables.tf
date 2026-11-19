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
