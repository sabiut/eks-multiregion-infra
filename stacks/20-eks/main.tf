# Stack 20: one EKS cluster and the AWS resources its add-ons need.
#
# This file is the table of contents. Each block calls one module from ../../modules:
#
#   cluster          control plane, access entries, managed add-ons, system node group
#   karpenter        Karpenter's IAM roles and interruption queue (Karpenter clusters only)
#   vault_unseal     KMS key that lets Vault unseal itself
#   velero_bucket    S3 bucket for cluster backups
#   addon_identity   IAM roles for the add-ons Argo CD installs (Pod Identity)

data "aws_caller_identity" "current" {}

locals {
  name       = "${var.environment}-${var.region}"
  account_id = data.aws_caller_identity.current.account_id

  # Short region code for IAM names: ap-southeast-2 -> apse2.
  short_region = replace(replace(replace(replace(replace(replace(replace(var.region,
  "southeast", "se"), "northeast", "ne"), "central", "c"), "south", "s"), "north", "n"), "west", "w"), "east", "e")
  iam_prefix = "${var.environment}-${replace(local.short_region, "-", "")}"

  use_karpenter = var.autoscaler == "karpenter"
}

module "cluster" {
  source = "../../modules/eks-cluster"

  name               = local.name
  iam_prefix         = local.iam_prefix
  kubernetes_version = var.kubernetes_version

  # From stack 10-network (see remote_state.tf).
  vpc_id     = local.network.vpc_id
  subnet_ids = local.network.backend_subnet_ids

  # Frontend and backend pods run on separate nodes in separate subnets. With Karpenter the
  # NodePools arrange that; without it, one managed node group per tier does.
  tier_node_groups = local.use_karpenter ? {} : {
    frontend = local.network.frontend_subnet_ids
    backend  = local.network.backend_subnet_ids
  }

  public_access_cidrs = var.public_access_cidrs

  # The pipeline's apply role is always an admin: Ansible uses it to install Argo CD.
  admin_principal_arns = concat(
    var.admin_principal_arns,
    ["arn:aws:iam::${local.account_id}:role/eks-multiregion-apply"],
  )
  developer_principal_arns = var.developer_principal_arns

  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
}

module "karpenter" {
  source = "../../modules/karpenter"
  count  = local.use_karpenter ? 1 : 0

  cluster_name = module.cluster.cluster_name
  iam_prefix   = local.iam_prefix
}

module "vault_unseal" {
  source = "../../modules/vault-unseal-key"

  cluster_name = local.name
}

# Velero saves Kubernetes objects (and volume snapshots) here on a schedule. Restoring them
# into another cluster is one of the disaster recovery paths in docs/dr-runbook.md.
module "velero_bucket" {
  source = "../../modules/private-bucket"

  name = "${local.name}-velero-${local.account_id}"
}

module "addon_identity" {
  source = "../../modules/addon-identity"

  cluster_name              = module.cluster.cluster_name
  iam_prefix                = local.iam_prefix
  velero_bucket_arn         = module.velero_bucket.arn
  vault_kms_key_arn         = module.vault_unseal.key_arn
  enable_cluster_autoscaler = !local.use_karpenter
}
