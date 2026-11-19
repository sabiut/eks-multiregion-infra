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

2. **Fence Sydney's database**, in three parts. All are done on the database, outside the
   cluster, because anything done inside the cluster can be undone: Argo CD's self-heal
   restores a paused Application, and an autoscaler can bring back pods scaled to zero.

   Part 1 makes the database itself refuse writes. This is the real fence: it applies to
   sessions that are already connected and to any client, however it reached the database.
   ```
   aws rds modify-db-parameter-group --region ap-southeast-2 --db-parameter-group-name lab-ap-southeast-2 \
        --parameters ParameterName=default_transaction_read_only,ParameterValue=1,ApplyMethod=immediate
   ```
   Part 2 stops new connections, by removing the rules from the security group. It is not
   enough alone: AWS keeps established connections open after a rule is removed.
   ```
   SG=$(aws ec2 describe-security-groups --region ap-southeast-2 \
        --filters Name=group-name,Values=lab-ap-southeast-2-database --query 'SecurityGroups[0].GroupId' --output text)
   aws ec2 describe-security-group-rules --region ap-southeast-2 --filters Name=group-id,Values=$SG \
        --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text \
     | xargs -r aws ec2 revoke-security-group-ingress --region ap-southeast-2 --group-id $SG --security-group-rule-ids
   ```
   Part 3 ends every session that is already open. The read-only setting only decides how
   a transaction starts, so a write transaction that was open before part 1 could still
   commit. Restarting the instance closes every connection and rolls back anything not yet
   committed. It comes back read-only, with no way in for new connections:
   ```
   aws rds reboot-db-instance --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2
   aws rds wait db-instance-available --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2
   ```
   Then set `fenced = true` in `envs/ap-southeast-2/15-database.tfvars` and merge it, so a
   later Terraform apply keeps the fence and does not undo it.

3. **Verify the fence before going on.** All four must hold:
   ```
   # the instance restarted after the fence was set: this time is later than step 2, part 1
   aws rds describe-events --region ap-southeast-2 --source-type db-instance --source-identifier lab-ap-southeast-2 \
        --duration 30 --query "Events[?contains(Message,'restarted')].Date" --output text
   # the parameter is applied (prints "in-sync"; "applying" or "pending-reboot" means it is not)
   aws rds describe-db-instances --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2 \
        --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' --output text
   # no way in for new connections (prints 0)
   aws ec2 describe-security-group-rules --region ap-southeast-2 --filters Name=group-id,Values=$SG \
        --query 'length(SecurityGroupRules[?!IsEgress])'
   ```
   and a write sent **straight to Sydney's own load balancer**, not through the
   accelerator, is refused. Sydney's load balancer is internet-facing, so it stays
   reachable by its own address whatever the accelerator does:
   ```
   SYD=http://$(kubectl --context lab-ap-southeast-2 -n demo get ingress demo-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   curl -s -X POST "$SYD/api/visits" | jq -c .      # must be the "database unavailable or read-only" error
   ```

4. **If the fence cannot be applied or verified, stop. This is a decision, not a step.**
   That is the situation in a real regional outage: Sydney's API does not answer, so you
   cannot fence it, and you cannot know whether it is still taking writes from clients that
   can reach it.

   | Choice | What you accept |
   | --- | --- |
   | Wait for Sydney | A longer outage. No data is lost or split |
   | Promote Singapore without a fence | Service returns sooner. Writes Sydney had not replicated are lost (the RPO). **And** if Sydney comes back before it is fenced, it will accept writes on its own load balancer address: two diverging databases, which cannot be merged automatically |

   Promoting without a fence needs a named person's decision, recorded with the time. If
   that is the decision, fencing Sydney (steps 2 and 3) becomes the first action the moment
   its API answers again, before anything else is touched there, and any writes it took in
   between have to be found and reconciled by hand. This lab has no automatic protection
   for this case. Production designs close the gap with a managed failover that fences for
   you (Aurora Global Database), or by keeping the standby's load balancer private.

5. **Let the replica catch up, then promote it.** Nothing can be written in Sydney now, so
   wait until Singapore has everything that was committed there: `ReplicaLag` for
   `lab-ap-southeast-1` in CloudWatch reads 0.
   ```
   aws cloudwatch get-metric-statistics --region ap-southeast-1 --namespace AWS/RDS --metric-name ReplicaLag \
        --dimensions Name=DBInstanceIdentifier,Value=lab-ap-southeast-1 --statistics Maximum --period 60 \
        --start-time "$(date -u -d '-5 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --query 'Datapoints[-1].Maximum'
   ```
   Then promote, wait, and protect it:
   ```
   aws rds promote-read-replica --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   aws rds wait db-instance-available --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   aws rds modify-db-instance --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1 \
        --deletion-protection --apply-immediately
   ```
   Deletion protection matters from this moment: this instance is now the only current copy
   of the data, and no Terraform run or mistake should be able to delete it.

   With no replica left, Sydney's old database can now also be stopped, which closes it
   completely (AWS starts a stopped instance again after seven days):
   ```
   aws rds stop-db-instance --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2
   ```

6. **Verify a write in Singapore before any user is sent there**, from inside the cluster:
   ```
   kubectl --context lab-ap-southeast-1 -n demo port-forward svc/demo-web 8080:80 &
   curl -s -X POST localhost:8080/api/visits | jq -c .     # must return a count, with "store": "postgres"
   ```
   A page that loads is not proof. nginx answers its health check even when the database
   refuses writes. The promoted database keeps the password it had as a replica, which the
   backend already holds, so nothing about credentials changes during the failover.

7. **Move the traffic.** In `envs/global/30-global.tfvars` replace the Sydney entry with
   `"ap-southeast-1" = 100`, then apply target `global`. The loop from step 1 shows counts
   again. The time from step 2 to here is your measured RTO.

8. Scale the standby for full load (in the GitOps repository, raise `autoscaling.minReplicas`
   for Singapore; Cluster Autoscaler adds nodes).

The failover ends here. Singapore is serving, with the credentials it already had.

### Afterwards, in a quiet period: bring Terraform in line

Terraform still describes Singapore as a replica. Correcting that also gives the new primary
its own master password and its own secret in Singapore, and **changing the password
interrupts database access** until the backend has the new one (a minute or two). So this is
a planned change, not part of the emergency.

1. In `envs/ap-southeast-1/15-database.tfvars` set `primary_region = ""` and
   `deletion_protection = true`. Plan the database stack for Singapore and read it:

   - It must say **0 to destroy**, and show `aws_db_instance.this` as *updated in place*.
   - If it shows the instance being destroyed or replaced, **stop and do not apply**.

2. Apply it. From this moment the backend's stored password is wrong, so do the next two
   steps straight away.
3. Hand the new outputs to Ansible and update Vault. The handoff must be run again here:
   without it, Ansible would read the old secret's address and write the old password back.
   ```
   scripts/handoff.sh ap-southeast-1
   cd ansible && ansible-playbook playbooks/vault.yml --limit ap-southeast-1
   ```
   Run the whole playbook, not part of it: the step that writes the password needs the
   Vault token that an earlier step loads. Every step checks before it acts.
4. **Verify a write again**, through the front door, once External Secrets has refreshed
   (up to a minute): the loop from the failover's step 1 must show counts rising.

### Fail back to Sydney

Do not re-register Sydney or reopen its database. After the promotion Singapore is the only
current copy. Sydney's old database is stale and is not a replica of anything.

1. Leave Sydney fenced and out of the accelerator.
2. Rebuild Sydney's database as a replica of Singapore (only after "bring Terraform in
   line" above is done, so Singapore's stack is the primary in state): in
   `envs/ap-southeast-2/15-database.tfvars` set `primary_region = "ap-southeast-1"` and
   `fenced = false`, then apply. The plan **replaces** Sydney's instance (a primary cannot
   be turned into a replica), which is intended here: the stale copy is the one being
   discarded. Check that the plan touches Sydney's stack only.
3. Wait for the replica to catch up (`ReplicaLag` in CloudWatch near zero).
4. **Give Sydney's backend the current credentials.** The rebuilt replica has Singapore's
   password, not the one Sydney's Vault still holds from before the failover:
   ```
   scripts/handoff.sh ap-southeast-2
   cd ansible && ansible-playbook playbooks/vault.yml --limit ap-southeast-2
   ```
5. **Verify Sydney can read its database before touching Singapore.** If this fails, the
   reverse cutover would get stuck half way, with Singapore fenced and Sydney unable to serve:
   ```
   kubectl --context lab-ap-southeast-2 -n demo port-forward svc/demo-web 8080:80 &
   curl -s localhost:8080/api/visits | jq -c .     # must return the current count, with "store": "postgres"
   ```
6. Run the failover steps in the other direction, in a quiet period: fence Singapore, verify,
   let Sydney catch up, promote Sydney, verify a write, move the traffic. Then bring
   Terraform in line.
7. Rebuild Singapore as the replica, then give its backend the credentials the same way
   (steps 4 and 5, for `ap-southeast-1`).

Many teams do not fail back at all: the region that took over stays primary, and the other
becomes the new standby (steps 1 to 5 only).

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
