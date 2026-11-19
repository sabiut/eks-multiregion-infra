# Karpenter's AWS side.
#
# The controller's IAM role (through Pod Identity), the IAM role its nodes use, an access
# entry so those nodes may join the cluster, and an SQS queue fed by EventBridge with spot
# interruption and rebalance notices, so Karpenter can drain a node before AWS takes it.
# The Karpenter controller itself, and its NodePool, are installed by Argo CD.

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.28"

  cluster_name = var.cluster_name

  namespace                       = "kube-system"
  service_account                 = "karpenter"
  create_pod_identity_association = true
  iam_role_name                   = "${var.iam_prefix}-karpenter"
  iam_role_use_name_prefix        = false

  # Attach the controller's permissions as an inline policy on its role. As a standalone
  # managed policy the document is over IAM's 6,144-character limit for managed policies
  # ("LimitExceeded: Cannot exceed quota for PolicySize"); an inline role policy may be
  # up to 10,240 characters.
  enable_inline_policy = true

  # Fixed names, so the GitOps repository can refer to them without copying IDs around.
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false
  queue_name                    = var.cluster_name

  # Session Manager access to nodes for troubleshooting, with no SSH keys.
  node_iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}
