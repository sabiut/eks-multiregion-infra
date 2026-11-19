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
| A region | The second region is already running. Promote its database, then move the traffic dials to it |
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

Both regions are running and `global` is applied. Sydney's traffic dial is 100 and
Singapore's is 0: the standby runs, but users are not sent to it, because its database is
read-only.

Failover is manual and ordered on purpose. The database decides the order: traffic must
never reach a region whose database cannot take writes, and two regions must never accept
writes at the same time.

### Fail over to Singapore

1. Watch the front door:
   ```
   URL=$(terraform -chdir=stacks/30-global output -raw url)
   while true; do curl -s -X POST "$URL/api/visits" | jq -c .; curl -s "$URL/api/info" | jq -r '"\(.region)  \(.version)"'; sleep 2; done
   ```
   Every line says `ap-southeast-2`, and the visit count rises.
2. **Fence Sydney's writes.** If Sydney is still reachable, stop its backend so nothing more
   is written there after the replica is cut loose:
   ```
   kubectl --context lab-ap-southeast-2 -n argocd patch application demo-api-prd --type merge -p '{"spec":{"syncPolicy":null}}'
   kubectl --context lab-ap-southeast-2 -n demo scale rollout demo-api --replicas 0
   ```
   In a real outage Sydney is already gone and this step is skipped. That is the case where
   writes not yet replicated are lost: the RPO.
3. **Promote Singapore's database** and wait until it is available:
   ```
   aws rds promote-read-replica --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   aws rds wait db-instance-available --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   ```
4. **Move the traffic.** In `envs/global/30-global.tfvars` set `"ap-southeast-1" = 100` and
   `"ap-southeast-2" = 0`, then apply target `global`.
5. **Verify a write, not just a page.** The loop from step 1 now says `ap-southeast-1` and
   the visit count rises again. A frontend that answers is not proof: nginx answers its
   health check even when the database refuses writes. The time from step 2 to the first
   successful write here is your measured RTO.
6. Scale the standby for full load (in the GitOps repository, raise `autoscaling.minReplicas`
   for Singapore; Cluster Autoscaler adds nodes).

### Fail back to Sydney

Do not simply turn Sydney's dial back up. After the promotion Singapore is the only current
copy. Sydney's old database is stale, it is not a replica of anything, and sending users to
it would show old data and create a second, diverging set of writes (split brain).

1. Keep Sydney's dial at 0 and its backend scaled to zero.
2. Rebuild Sydney's database from Singapore: destroy the old Sydney instance, then create it
   again as a read replica of Singapore (swap the roles in the two `15-database.tfvars`
   files: Singapore's `primary_region` becomes empty, Sydney's becomes `ap-southeast-1`).
   Changing an existing instance from primary to replica is a replacement, so read the plan.
3. Wait for the replica to catch up (`ReplicaLag` in CloudWatch near zero).
4. Repeat the failover steps in the other direction, in a quiet period: fence Singapore's
   writes, promote Sydney, move the dials, verify a write.
5. Re-create Singapore as the replica.

Many teams do not fail back at all: the region that took over stays primary, and the other
becomes the new standby (steps 2 and 3 only).

Terraform note: after `promote-read-replica`, Terraform still describes Singapore as a
replica. The role swap in step 2 is what brings the code back in line. In a drill you can
instead destroy and re-apply Singapore's database stack to get the replica back.

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
