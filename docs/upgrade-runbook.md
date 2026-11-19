# Upgrading Kubernetes on EKS

An upgrade here means moving the **cluster** to a newer Kubernetes version (1.36 to 1.37).
It is not an application release. AWS runs the control plane, but you choose when to
upgrade, and you own the checks, the add-ons and the nodes.

## The rules

- **One minor version at a time.** 1.35 to 1.37 is two upgrades.
- **Order: control plane, then add-ons, then nodes.** The kubelet on a node may be older than
  the control plane, never newer.
- **Standby region first.** Singapore carries no traffic, so it is where to find problems.
  Sydney follows once Singapore has run the new version for a while.
- **A control plane upgrade cannot be rolled back.** The way back is a new cluster, which is
  one more reason to test in the standby region first.
- **Stay inside standard support.** Each version gets about 14 months of standard support,
  then paid extended support, then AWS upgrades the control plane for you on its schedule.
  (Check the EKS version calendar for current dates.)

## What happens on `terraform apply`

`kubernetes_version` in `envs/<region>/20-eks.tfvars` is the only thing you change.

| Part | What Terraform asks EKS to do | Downtime |
| --- | --- | --- |
| Control plane | Start new API servers on the new version, then switch over | None for workloads. The API stays available |
| Managed add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI, Pod Identity agent) | Move each to the default version for the new Kubernetes version | Rolling |
| Managed node group | Start nodes from the new AMI, cordon and drain the old ones, a third at a time (`update_config`) | None if the application has more than one replica and a PodDisruptionBudget |
| Karpenter nodes | Nothing directly. The `al2023@latest` AMI alias now points at a newer image, Karpenter sees its nodes have "drifted" and replaces them one at a time | Same as above |

Things that are **not** upgraded for you: Helm-installed add-ons (Karpenter, Cluster
Autoscaler, the load balancer controller, Argo CD ...). Check each one's compatibility table
and raise its chart version in the GitOps repository. Cluster Autoscaler in particular should
match the cluster's minor version.

## Steps

1. **Read** the Kubernetes and EKS release notes for the target version. Look for removed APIs.
2. **Pre-check** (read-only): Actions > **upgrade-precheck**, region `ap-southeast-1`, target `1.37`.
   It reports:
   - EKS upgrade insights (AWS's own scan for things that will break)
   - calls to deprecated APIs the API server has seen
   - node versions
   - PodDisruptionBudgets that allow zero disruptions (they block a drain)
   - the add-on versions the cluster will move to
3. **Fix** anything it found: update manifests and charts that use removed APIs, raise
   controller chart versions, correct any PodDisruptionBudget that blocks all evictions.
4. **Upgrade the standby.** Pull request: `kubernetes_version = "1.37"` in
   `envs/ap-southeast-1/20-eks.tfvars`. Read the plan on the pull request. Merge, then run
   **deploy** with target `ap-southeast-1`, action `apply`.
5. **Verify.**
   ```
   kubectl get nodes                       # every node on the new version, Ready
   kubectl -n argocd get applications      # all Synced and Healthy
   kubectl get pods -A | grep -v Running   # nothing stuck
   ```
   Send a request through the application. Check dashboards and alerts.
6. **Wait**, then repeat steps 2 to 5 for `ap-southeast-2`. While Sydney's nodes are being
   replaced, watch the canary-style safety nets do their work:
   ```
   kubectl -n demo get pods -o wide -w     # pods move node by node, never all at once
   kubectl -n demo get pdb                 # ALLOWED DISRUPTIONS stays above zero
   ```

## Other strategies, and when to use them

| Strategy | How | When |
| --- | --- | --- |
| In-place (this runbook) | Upgrade the existing cluster, part by part | The default. Cheapest and simplest |
| Blue-green cluster | Build a second cluster on the new version, deploy with GitOps, shift traffic, delete the old one | A risky jump, several versions behind, or when a real rollback is required |
| Blue-green node group | Add a new node group on the new version, cordon and drain the old one, delete it | When you want to control the node move yourself |

Because every cluster here is built from Git (Terraform plus Argo CD), a second cluster is a
realistic option: it is the same code with another name.
