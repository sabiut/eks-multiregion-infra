# The EKS cluster: control plane, who may use it, managed add-ons and the system node group.

locals {
  # ---- Who may use the cluster: EKS access entries ----
  # An access entry maps an IAM principal to Kubernetes permissions. It replaces the old
  # aws-auth ConfigMap. Two styles are shown:
  #   admins      get an AWS-managed access policy (cluster admin).
  #   developers  get no AWS policy at all, only membership of the Kubernetes group
  #               "developers". A Role and RoleBinding in the apps repo decide what that
  #               group can do. This is how IAM identities connect to Kubernetes RBAC.
  access_entries = merge(
    {
      for arn in var.admin_principal_arns :
      "admin-${md5(arn)}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      for arn in var.developer_principal_arns :
      "dev-${md5(arn)}" => {
        principal_arn     = arn
        kubernetes_groups = ["developers"]
      }
    }
  )
}

locals {
  # ---- One managed node group per application tier (Cluster Autoscaler clusters) ----
  # Each group's nodes start in that tier's subnets and carry the label tier=<name>. A
  # workload picks its tier with a nodeSelector, and with the VPC CNI its pods then get
  # addresses from that tier's subnets. In a Karpenter cluster this map is empty: Karpenter's
  # NodePools do the same job (see the GitOps repository).
  tier_node_groups = {
    for tier, subnet_ids in var.tier_node_groups : tier => {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.tier_instance_types
      subnet_ids     = subnet_ids
      min_size       = 1
      max_size       = 3
      desired_size   = 1

      update_config = { max_unavailable_percentage = 33 }
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      labels = { tier = tier }
      tags = {
        "k8s.io/cluster-autoscaler/enabled"     = "true"
        "k8s.io/cluster-autoscaler/${var.name}" = "owned"
      }
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.28"

  name = var.name
  # UPGRADES: this one value drives the control plane version. Managed add-ons without a
  # pinned version and the managed node group follow it on the same apply.
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_access_cidrs

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  access_entries                           = local.access_entries

  # Kubernetes Secrets are envelope-encrypted with a KMS key the module creates.
  encryption_config = { resources = ["secrets"] }

  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  # EKS managed add-ons: AWS keeps a version of each that matches the cluster version.
  addons = {
    vpc-cni = {
      before_compute = true
      # Lets the VPC CNI enforce Kubernetes NetworkPolicy objects.
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # ---- Managed node group: the "system" nodes ----
  # AWS owns the Auto Scaling group and replaces nodes for upgrades. It holds the add-ons
  # (Argo CD, Karpenter, Vault ...) and lives in the backend subnets. The application runs on
  # separate nodes per tier: Karpenter's in a Karpenter cluster, the tier node groups above
  # in a Cluster Autoscaler cluster.
  eks_managed_node_groups = merge(local.tier_node_groups, {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # During a node group upgrade, replace at most a third of the nodes at a time.
      update_config = { max_unavailable_percentage = 33 }

      # IMDSv2 only, hop limit 1: pods cannot borrow the node's IAM role.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      labels = { role = "system" }
      # Cluster Autoscaler finds node groups by these tags.
      tags = {
        "k8s.io/cluster-autoscaler/enabled"     = "true"
        "k8s.io/cluster-autoscaler/${var.name}" = "owned"
      }
    }
  })

  # Karpenter gives its nodes the security group carrying this tag (see the EC2NodeClass).
  node_security_group_tags = { "karpenter.sh/discovery" = var.name }
}

# IAM role for the EBS CSI driver add-on. It lives here, not in the addon-identity module,
# because the add-on above creates the Pod Identity association itself and needs the role
# before the cluster's add-ons are installed.
module "ebs_csi_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.8"

  name                      = "${var.iam_prefix}-ebs-csi"
  attach_aws_ebs_csi_policy = true
}
