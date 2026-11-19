# Pod Identity: one IAM role per add-on ServiceAccount.
#
# A pod using that ServiceAccount gets that role's temporary credentials. Nothing else in the
# cluster can use them, and no keys are stored. The add-ons themselves are installed by
# Argo CD; this module only prepares the AWS permissions they will find waiting.

locals {
  identities = merge(
    {
      "aws-lb-controller" = {
        namespace       = "kube-system"
        service_account = "aws-load-balancer-controller"
      }
      "velero" = {
        namespace       = "velero"
        service_account = "velero"
      }
      "vault" = {
        namespace       = "vault"
        service_account = "vault"
      }
    },
    var.enable_cluster_autoscaler ? {
      "cluster-autoscaler" = {
        namespace       = "kube-system"
        service_account = "cluster-autoscaler"
      }
    } : {}
  )
}

module "pod_identity" {
  source   = "terraform-aws-modules/eks-pod-identity/aws"
  version  = "~> 2.8"
  for_each = local.identities

  name = "${var.iam_prefix}-${each.key}"

  attach_aws_lb_controller_policy  = each.key == "aws-lb-controller"
  attach_cluster_autoscaler_policy = each.key == "cluster-autoscaler"
  cluster_autoscaler_cluster_names = [var.cluster_name]

  # Velero may read and write its backup bucket.
  attach_velero_policy       = each.key == "velero"
  velero_s3_bucket_arns      = [var.velero_bucket_arn]
  velero_s3_bucket_path_arns = ["${var.velero_bucket_arn}/*"]

  # Vault may use one KMS key, to unseal itself.
  attach_custom_policy = each.key == "vault"
  policy_statements = each.key != "vault" ? null : [{
    sid       = "VaultAutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [var.vault_kms_key_arn]
  }]

  associations = {
    this = {
      cluster_name    = var.cluster_name
      namespace       = each.value.namespace
      service_account = each.value.service_account
    }
  }
}
