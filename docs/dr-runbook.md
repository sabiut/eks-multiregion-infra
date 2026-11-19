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
| A region | The second region is already running. Fence the old database, promote the replica, verify a write, then register the region with the accelerator |
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

Both regions are running and `global` is applied. Only Sydney is registered with the
accelerator. Singapore runs the application as a warm standby, but no user can reach it,
because its database is read-only.

Failover is manual and ordered on purpose. Two rules decide the order:

- Users must never be sent to a region whose database cannot take writes.
- Two databases must never accept writes at the same time (split brain).

**This procedure has not been run.** It was written and reviewed against the code and the
Terraform plans only. Run it as a drill before relying on it.

### Fail over to Singapore

1. Watch the front door:
   ```
   URL=$(terraform -chdir=stacks/30-global output -raw url)
   while true; do curl -s -m 3 -X POST "$URL/api/visits" | jq -c .; sleep 2; done
   ```
   The visit count rises, served by `ap-southeast-2`.

2. **Fence Sydney's database.** Close it to every client by removing the rules from its
   security group. This is done at the network layer, outside the cluster, because anything
   done inside the cluster can be undone: Argo CD's self-heal restores an Application that
   was paused, and an autoscaler can bring back pods that were scaled to zero.
   ```
   SG=$(aws ec2 describe-security-groups --region ap-southeast-2 \
        --filters Name=group-name,Values=lab-ap-southeast-2-database --query 'SecurityGroups[0].GroupId' --output text)
   aws ec2 describe-security-group-rules --region ap-southeast-2 --filters Name=group-id,Values=$SG \
        --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text \
     | xargs -r aws ec2 revoke-security-group-ingress --region ap-southeast-2 --group-id $SG --security-group-rule-ids
   ```
   Then set `fenced = true` in `envs/ap-southeast-2/15-database.tfvars` and merge it, so a
   later Terraform apply keeps the fence and does not put the rules back.

3. **Verify the fence before going on.** The loop from step 1 must now show
   `"error": "database unavailable or read-only"` on every line, and the security group
   must have no ingress rules:
   ```
   aws ec2 describe-security-group-rules --region ap-southeast-2 --filters Name=group-id,Values=$SG \
        --query 'length(SecurityGroupRules[?!IsEgress])'        # must print 0
   ```
   **If Sydney cannot be reached at all** (a real regional outage), the fence cannot be
   applied or verified now. Carry on, and treat it as owed: it must be applied and verified
   the moment the region's API answers again, before anything else is done in Sydney. Until
   then Sydney is not registered with the accelerator (step 6), so users cannot reach it.
   Writes that had not replicated when Sydney was lost are gone: that is the RPO.

4. **Promote Singapore's database**, wait, and protect it:
   ```
   aws rds promote-read-replica --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   aws rds wait db-instance-available --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   aws rds modify-db-instance --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1 \
        --deletion-protection --apply-immediately
   ```
   Deletion protection matters from this moment: this instance is now the only current copy
   of the data, and no Terraform run or mistake should be able to delete it.

5. **Verify a write in Singapore before any user is sent there**, from inside the cluster:
   ```
   kubectl --context lab-ap-southeast-1 -n demo port-forward svc/demo-web 8080:80 &
   curl -s -X POST localhost:8080/api/visits | jq -c .     # must return a count, with "store": "postgres"
   ```
   A page that loads is not proof. nginx answers its health check even when the database
   refuses writes.

6. **Move the traffic.** In `envs/global/30-global.tfvars` replace the Sydney entry with
   `"ap-southeast-1" = 100`, then apply target `global`. The loop from step 1 shows counts
   again. The time from step 2 to here is your measured RTO.

7. **Bring Terraform in line with reality.** In `envs/ap-southeast-1/15-database.tfvars` set
   `primary_region = ""` and `deletion_protection = true`. Plan the database stack for
   Singapore and read it before applying:

   - It must say **0 to destroy**, and show `aws_db_instance.this` as *updated in place*.
   - If it shows the instance being destroyed or replaced, **stop and do not apply**.

   The module uses one resource for both roles so that this change is an update, not a
   delete and re-create. The update gives the new primary its own master password and its
   own secret in Singapore; run the `vault.yml` playbook for Singapore afterwards so the
   backend picks them up.

8. Scale the standby for full load (in the GitOps repository, raise `autoscaling.minReplicas`
   for Singapore; Cluster Autoscaler adds nodes).

### Fail back to Sydney

Do not re-register Sydney or reopen its database. After the promotion Singapore is the only
current copy. Sydney's old database is stale and is not a replica of anything.

1. Leave Sydney fenced and out of the accelerator.
2. Rebuild Sydney's database as a replica of Singapore: in
   `envs/ap-southeast-2/15-database.tfvars` set `primary_region = "ap-southeast-1"` and
   `fenced = false`, then apply. The plan **replaces** Sydney's instance (a primary cannot
   be turned into a replica), which is intended here: the stale copy is the one being
   discarded. Check that the plan touches Sydney's stack only.
3. Wait for the replica to catch up (`ReplicaLag` in CloudWatch near zero).
4. Run the failover steps in the other direction, in a quiet period: fence Singapore, verify,
   promote Sydney, verify a write, move the traffic, bring Terraform in line.
5. Rebuild Singapore as the replica.

Many teams do not fail back at all: the region that took over stays primary, and the other
becomes the new standby (steps 1 to 3 only).

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
