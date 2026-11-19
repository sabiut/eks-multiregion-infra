environment = "lab"
region      = "ap-southeast-1"

# Upgrade the standby region first: it carries no traffic, so it is the safest place to find
# problems. Then change the primary.
kubernetes_version = "1.36"

# Singapore is the standby region and uses Cluster Autoscaler, to compare with Karpenter.
autoscaler = "cluster-autoscaler"

admin_principal_arns     = []
developer_principal_arns = []

node_instance_types = ["t3.large"]
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 2
