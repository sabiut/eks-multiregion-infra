# Disaster recovery

## Words first

| Term | Meaning |
| --- | --- |
| RTO, recovery time objective | How long the service may be down |
| RPO, recovery point objective | How much recent data may be lost |
| High availability | Surviving the loss of a node or an availability zone, inside one region. Three zones, several replicas, PodDisruptionBudgets |
| Disaster recovery | Surviving the loss of a whole region, or of the cluster itself |
| Backup and restore | Nothing runs in the second region until needed. Cheapest, slowest (hours) |
| Pilot light | Data is replicated and the core is ready, but compute is off or minimal |
| Warm standby | A smaller copy runs all the time and scales up on failover. **This lab** |
| Active-active | Both regions serve users all the time. Fastest, most expensive, hardest for data |

## What protects what in this lab

| If you lose | What brings it back |
| --- | --- |
| A pod | Kubernetes restarts it. The readiness probe keeps traffic away until it is ready |
| A node | Pods are rescheduled. Karpenter or Cluster Autoscaler adds a node if needed |
| An availability zone | Pods are spread across three zones (topology spread). The load balancer stops using the lost zone |
| A whole cluster's configuration | Git. Run the deploy workflow: Terraform rebuilds the cluster, Ansible installs Argo CD, Argo CD reinstalls everything |
| Kubernetes objects that are not in Git, or a namespace deleted by mistake | Velero: scheduled backups to S3, restored with one command |
| A region | The second region is already running. Global Accelerator moves traffic to it |
| Container images | Each region has its own ECR repository holding the same tags |
| Vault's unseal ability | The KMS key (auto-unseal). The recovery keys are in Secrets Manager |

| The database instance or its availability zone | In production, Multi-AZ: RDS fails over to a standby in another zone by itself. The lab runs one instance |
| The database's region | The cross-region read replica in Singapore, promoted to a writable database |

**Data is the hard part.** Stateless pods fail over in a minute. The database decides your
real RTO and RPO. The replica is asynchronous, so the RPO is the replication lag at the
moment Sydney is lost (normally seconds). Promotion is one-way: afterwards the old primary
is not a replica of the new one, and failing back means building a new replica in Sydney.
Aurora Global Database does the same job with faster, managed failover. Vault in production
would use Raft storage with snapshots copied to the other region, or its own replication.

## Drill 1: region failover

Both regions are running and `global` is applied.

1. Find the front door and watch which region answers:
   ```
   URL=$(terraform -chdir=stacks/30-global output -raw url)
   while true; do curl -s "$URL/api/info" | jq -r '"\(.region)  \(.version)  \(.pod)"'; sleep 2; done
   ```
   From Australia every line says `ap-southeast-2`: the accelerator sends you to the nearest
   healthy region.
2. Break Sydney. Either take it out on purpose, by changing `"ap-southeast-2"` to `0` in
   `envs/global/30-global.tfvars` and applying target `global`, or simulate a failure by
   making every pod there unready:
   ```
   kubectl --context lab-ap-southeast-2 -n argocd patch application demo-web-prd --type merge -p '{"spec":{"syncPolicy":null}}'
   kubectl --context lab-ap-southeast-2 -n demo scale deployment demo-web --replicas 0
   ```
3. Watch the loop. Within about a minute the lines say `ap-southeast-1`. The time between
   the last Sydney line and the first Singapore line is your measured RTO.
4. Make the database writable in Singapore. Until this step, reads work there and "Record a
   visit" fails, because a replica is read-only:
   ```
   aws rds promote-read-replica --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   ```
   Terraform still describes it as a replica, so after a real promotion you would update
   `envs/ap-southeast-1/15-database.tfvars` to make Singapore the primary. In a drill, skip
   this step, or destroy and re-apply Singapore's database afterwards.
5. Scale the standby for full load (in the GitOps repository, raise `autoscaling.minReplicas`
   for Singapore; Cluster Autoscaler adds nodes).
6. Fail back: undo step 2 (re-enable sync in Argo CD, or set the dial back to 100).

## Drill 2: restore a deleted namespace with Velero

```
velero backup create demo-now --include-namespaces demo --wait
for app in demo-web-prd demo-api-prd; do
  kubectl -n argocd patch application $app --type merge -p '{"spec":{"syncPolicy":null}}'
done
kubectl -n demo delete rollout,deployment,svc,hpa,pdb,ingress --all      # the "accident"
velero restore create --from-backup demo-now --wait
kubectl -n demo get pods
```

Then turn Argo CD's sync back on. In real life Git would restore these objects too; Velero
matters most for what Git does not hold, such as persistent volumes and objects created by hand.

## Drill 3: rebuild a cluster from nothing

Destroy the standby region with the deploy workflow, then apply it again. Nothing is done by
hand: about 25 minutes later it serves the application at the version Git says. That is the
strongest disaster recovery claim an infrastructure-as-code platform can make.
