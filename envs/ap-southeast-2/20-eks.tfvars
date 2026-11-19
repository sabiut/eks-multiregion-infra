environment = "lab"
region      = "ap-southeast-2"

# Start one minor version behind the newest, so the upgrade runbook has something to do.
kubernetes_version = "1.36"

# Sydney is the primary region and uses Karpenter for nodes.
autoscaler = "karpenter"

# IAM users or roles that should be cluster admins, for kubectl from a laptop. Supplied at
# run time so no account ID is committed: the workflow adds the identity in the repository
# secret CLUSTER_ADMIN_ARN.
admin_principal_arns     = []
developer_principal_arns = []

# LAB PROFILE: two system nodes. Production: three, one per AZ.
node_instance_types = ["t3.large"]
node_min_size       = 2
node_max_size       = 3
node_desired_size   = 2
