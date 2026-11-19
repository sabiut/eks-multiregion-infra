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
| Terraform's state | **Not protected in this lab.** The state bucket is in Sydney, so with Sydney down Terraform cannot plan or apply anything, in any region. The failover below therefore has a path that uses only the AWS CLI. Production: replicate the bucket to a second region, or keep it in a third |

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

**Scope.** The write fence in this procedure is complete for this lab, where the demo backend
is the only database client and never overrides a read-only default. It is not a general
guarantee for a database with other clients. Step 4 says exactly where the limit is.

### What has been tested, and what has not

| Part | Status |
| --- | --- |
| The database steps: the fence, the restart, the final WAL position, the replica catching up, promotion | Rehearsed on two local PostgreSQL containers with `scripts/drill-local.sh`. Run it yourself: it takes a minute and needs only Docker |
| `scripts/check-app.sh` and `scripts/db-psql.sh` | Run on a local Kubernetes cluster (kind) against the real charts and a PostgreSQL with TLS: a read, a write, a fenced database, the wrong region answering, two checks at once, a failing SQL statement |
| Everything that is AWS: RDS parameter groups, security groups, the accelerator, Terraform's role change, Vault | **Never run.** Written and reviewed against the code and the Terraform plans only. Drill it on real infrastructure before relying on it |

Three scripts do the checking, so no step depends on reading a number off a screen:

| Script | What it does |
| --- | --- |
| `scripts/check-app.sh <region> read\|write\|refused` | Asks that region's application, through the cluster. Confirms which region answered, then that a read works, a write is stored, or a write is refused |
| `scripts/db-psql.sh <region> "<sql>"` | Runs one SQL statement against that region's database, from a short-lived pod on a backend node |
| `scripts/handoff.sh <region>` | Writes Terraform's current outputs for Ansible |

### Fail over to Singapore (planned, or Sydney is still reachable)

If Sydney's AWS API or cluster does not answer, go to "If Sydney cannot be reached" below.

0. **Check the standby before touching the primary.** Both must pass:
   ```
   scripts/check-app.sh ap-southeast-1 read
   aws rds describe-db-instances --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1 \
        --query 'DBInstances[0].StatusInfos[?StatusType==`read replication`].Status' --output text    # replicating
   ```

1. Watch the front door in a second terminal:
   ```
   URL=$(scripts/tf.sh output 30-global global | jq -r .url.value)
   while true; do curl -s -m 3 -X POST "$URL/api/visits" | jq -c .; sleep 2; done
   ```
   The visit count rises.

2. **Fence Sydney's database.** Make it refuse writes, then restart it. Both are done on the
   database, outside the cluster, because anything done inside the cluster can be undone:
   Argo CD's self-heal restores a paused Application, and an autoscaler can bring back pods
   that were scaled to zero.
   ```
   aws rds modify-db-parameter-group --region ap-southeast-2 --db-parameter-group-name lab-ap-southeast-2 \
        --parameters ParameterName=default_transaction_read_only,ParameterValue=1,ApplyMethod=immediate
   ```
   Wait until the database reports the setting. Repeat until this prints `on`:
   ```
   scripts/db-psql.sh ap-southeast-2 "SHOW default_transaction_read_only"
   ```
   Only then restart, noting the database's own clock first:
   ```
   SET_AT=$(scripts/db-psql.sh ap-southeast-2 "SELECT now()")
   aws rds reboot-db-instance --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2
   aws rds wait db-instance-available --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2
   ```
   The setting makes every new transaction read-only. It does not touch a transaction that
   was already open, which could still commit. The restart closes every session and rolls
   back anything uncommitted. The order matters: the restart must come after the setting is
   in force, or a session opened in between could still hold a write transaction.
   (`scripts/drill-local.sh` shows both halves of this.)

   Sydney's dev and stg environments use the same database in this lab, so they stop
   accepting writes too.

3. **Verify the fence.** All four must pass before going on:
   ```
   scripts/db-psql.sh ap-southeast-2 "SHOW default_transaction_read_only"                            # on
   scripts/db-psql.sh ap-southeast-2 "SELECT pg_postmaster_start_time() > '$SET_AT'"                 # t
   scripts/check-app.sh ap-southeast-2 refused
   aws rds describe-db-instances --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2 \
        --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' --output text              # in-sync
   ```
   The second line proves the restart happened after the setting was in force, by the
   database's own clock. The third proves
   the application cannot write, whichever way a user reaches it: the refusal comes from
   the database, so it also covers Sydney's own load balancer address, which stays
   reachable from the internet whatever the accelerator does.

4. **Record the primary's final position**, after checking nothing else is writing.

   **What this step assumes.** The fence is a default, not a lock: it stops any client that
   does not explicitly ask for a read-write transaction. The demo backend never asks, and it
   is the only client of this database, so for this lab the fence is complete. It is **not**
   a guarantee against other clients. A migration tool, an admin session or another service
   that starts a transaction with `BEGIN READ WRITE` could still commit after the position
   below is recorded, and that commit could be missing from the promoted database.

   So first look for any session that is writing or holding a transaction open. This must
   print `0`:
   ```
   scripts/db-psql.sh ap-southeast-2 "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND (backend_xid IS NOT NULL OR state LIKE 'idle in transaction%')"
   ```
   If it is not 0, find out what the session is and end it
   (`SELECT pg_terminate_backend(pid)`) before going on. This is a check at one moment, not
   a lock: it shows nothing is writing now, it cannot stop a new session a second later.

   Then record the position. Everything this application ever committed is at or before it:
   ```
   FINAL_LSN=$(scripts/db-psql.sh ap-southeast-2 "SELECT pg_current_wal_lsn()")
   echo "$FINAL_LSN"       # looks like 0/30270A8
   ```
   Go straight on to step 5: the shorter the gap between this step and the closed door, the
   less room for the case described above.

   A system with more than one kind of database client needs more than this lab has: each
   client on its own database role, so the roles can be locked (`ALTER ROLE ... NOLOGIN`)
   and their sessions ended before the position is read, leaving one operator role to read it.

5. **Close the door.** Remove the rules from the database's security group, so nothing can
   connect at all. (This comes after step 4, because step 4 needs to connect.)
   ```
   SG=$(aws ec2 describe-security-groups --region ap-southeast-2 \
        --filters Name=group-name,Values=lab-ap-southeast-2-database --query 'SecurityGroups[0].GroupId' --output text)
   aws ec2 describe-security-group-rules --region ap-southeast-2 --filters Name=group-id,Values=$SG \
        --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text \
     | xargs -r aws ec2 revoke-security-group-ingress --region ap-southeast-2 --group-id $SG --security-group-rule-ids
   aws ec2 describe-security-group-rules --region ap-southeast-2 --filters Name=group-id,Values=$SG \
        --query 'length(SecurityGroupRules[?!IsEgress])'        # 0
   ```
   This stops new connections only; AWS can keep an established connection open after its
   rule is removed. That is harmless here, because step 2 already made every session
   read-only.

   From here no new connection can be made. Together with step 2's restart, which ended
   the sessions that existed then, that leaves only a connection opened between step 2 and
   now, and such a connection writes only if its client explicitly asks for read-write (see
   the assumption in step 4).

   Then set `fenced = true` in `envs/ap-southeast-2/15-database.tfvars` and merge
   it, so a later Terraform apply keeps the fence (the setting and the closed door) and does
   not undo it.

6. **Wait until the replica has everything.** It has when it has replayed past the position
   from step 4. Repeat until this prints `t`:
   ```
   scripts/db-psql.sh ap-southeast-1 "SELECT pg_last_wal_replay_lsn() >= '$FINAL_LSN'::pg_lsn"
   ```
   Do not use the `ReplicaLag` metric for this decision. It is a time, not a position, its
   samples come back from CloudWatch in no particular order, and it drifts while the
   primary is idle. Comparing positions is exact.

7. **Promote Singapore's database**, wait, and protect it:
   ```
   aws rds promote-read-replica --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   aws rds wait db-instance-available --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1
   aws rds modify-db-instance --region ap-southeast-1 --db-instance-identifier lab-ap-southeast-1 \
        --deletion-protection --apply-immediately
   ```
   Deletion protection matters from this moment: this instance is now the only current copy
   of the data, and no Terraform run or mistake should be able to delete it.

8. **Verify a write in Singapore before any user is sent there:**
   ```
   scripts/check-app.sh ap-southeast-1 write
   ```
   A page that loads is not proof: nginx answers its health check even when the database
   refuses writes. The promoted database keeps the password it had as a replica, which the
   backend already holds, so nothing about credentials changes during the failover.

9. **Move the traffic.** In `envs/global/30-global.tfvars` replace the Sydney entry with
   `"ap-southeast-1" = 100`, then apply target `global`. The loop from step 1 shows counts
   again. The time from step 2 to here is your measured RTO.

10. Scale the standby for full load (in the GitOps repository, raise
    `autoscaling.minReplicas` for Singapore; Cluster Autoscaler adds nodes).

The failover ends here. Singapore is serving, with the credentials it already had.

### If Sydney cannot be reached

A real regional outage. Sydney's API does not answer, so it cannot be fenced, its final
position cannot be read, and you cannot know whether it is still taking writes from clients
that can reach it. **This is a decision, not a step.**

| Choice | What you accept |
| --- | --- |
| Wait for Sydney | A longer outage. No data is lost or split |
| Promote Singapore without a fence | Service returns sooner. Writes Sydney had not replicated are lost (the RPO). **And** if Sydney comes back before it is fenced, it will accept writes on its own load balancer address: two diverging databases, which cannot be merged automatically |

Promoting without a fence needs a named person's decision, recorded with the time. This lab
has no automatic protection for this case. Production designs close the gap with a managed
failover that fences for you (Aurora Global Database), or by keeping the standby region's
load balancer private.

If the decision is to promote:

1. Let Singapore finish applying what it has already received. Repeat until this prints `t`:
   ```
   scripts/db-psql.sh ap-southeast-1 "SELECT pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn()"
   ```
2. Promote and protect it (step 7 above), then verify a write (step 8 above).
3. Move the traffic **with the AWS CLI**. Terraform cannot be used: its state bucket is in
   Sydney. The accelerator's own API is in `us-west-2` and still answers:
   ```
   ACC=$(aws globalaccelerator list-accelerators --region us-west-2 --query "Accelerators[?Name=='lab-demo'].AcceleratorArn" --output text)
   LIS=$(aws globalaccelerator list-listeners --region us-west-2 --accelerator-arn $ACC --query 'Listeners[0].ListenerArn' --output text)
   HOST=$(kubectl --context lab-ap-southeast-1 -n demo get ingress demo-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   ALB=$(aws elbv2 describe-load-balancers --region ap-southeast-1 --query "LoadBalancers[?DNSName=='$HOST'].LoadBalancerArn" --output text)
   aws globalaccelerator create-endpoint-group --region us-west-2 --listener-arn $LIS --endpoint-group-region ap-southeast-1 \
        --endpoint-configurations EndpointId=$ALB,Weight=100,ClientIPPreservationEnabled=false
   OLD=$(aws globalaccelerator list-endpoint-groups --region us-west-2 --listener-arn $LIS \
        --query "EndpointGroups[?EndpointGroupRegion=='ap-southeast-2'].EndpointGroupArn" --output text)
   aws globalaccelerator delete-endpoint-group --region us-west-2 --endpoint-group-arn $OLD
   ```
4. **The fence is now owed.** The moment Sydney's API answers again, and before anything
   else is touched there, apply and verify it (steps 2, 3 and 5 above). Any writes Sydney
   took in between have to be found and reconciled by hand.
5. When Terraform can reach its state again, make it match what the CLI did, in this order:

   - Change `envs/global/30-global.tfvars` as in step 9 (Singapore in, Sydney out). The
     import below needs this first: the address it names only exists once Singapore is in
     that file.
   - Adopt the endpoint group the CLI created. `tf.sh` connects to the right state and
     passes the variables file; a bare `terraform import` would do neither:
     ```
     NEW=$(aws globalaccelerator list-endpoint-groups --region us-west-2 --listener-arn $LIS \
          --query "EndpointGroups[?EndpointGroupRegion=='ap-southeast-1'].EndpointGroupArn" --output text)
     scripts/tf.sh import 30-global global 'module.front_door.aws_globalaccelerator_endpoint_group.region["ap-southeast-1"]' "$NEW"
     ```
   - Plan and read it before applying: `scripts/tf.sh plan 30-global global`. It should
     create nothing. Sydney's endpoint group, which the CLI deleted, simply drops out of
     the state.

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
   (cd ansible && ansible-playbook playbooks/vault.yml --limit ap-southeast-1)
   ```
   Run the whole playbook, not part of it: the step that writes the password needs the
   Vault token that an earlier step loads. Every step checks before it acts.
4. **Verify a write again**, once External Secrets has refreshed (up to a minute):
   ```
   scripts/check-app.sh ap-southeast-1 write
   ```

### Fail back to Sydney

Do not re-register Sydney or reopen its database. After the promotion Singapore is the only
current copy. Sydney's old database is stale and is not a replica of anything.

1. Leave Sydney fenced and out of the accelerator. Finish "bring Terraform in line" above
   first, so Singapore's stack is the primary in Terraform's state.
2. **Rebuild Sydney's database as a replica of Singapore.** In
   `envs/ap-southeast-2/15-database.tfvars` set `primary_region = "ap-southeast-1"` and
   `fenced = false`, then apply Sydney's database stack. The plan **replaces** Sydney's
   instance (a primary cannot be turned into a replica), which is intended here: the stale
   copy is the one being discarded. Check that the plan touches Sydney's stack only.
   While Sydney's database is a replica, the dev and stg environments that share it in this
   lab can read but not write.
3. Wait until it is a working replica:
   ```
   aws rds describe-db-instances --region ap-southeast-2 --db-instance-identifier lab-ap-southeast-2 \
        --query 'DBInstances[0].StatusInfos[?StatusType==`read replication`].Status' --output text    # replicating
   ```
4. **Give Sydney's backend the current credentials.** The rebuilt replica has Singapore's
   password, not the one Sydney's Vault still holds from before the failover:
   ```
   scripts/handoff.sh ap-southeast-2
   (cd ansible && ansible-playbook playbooks/vault.yml --limit ap-southeast-2)
   ```
5. **Verify Sydney can read its database before touching Singapore.** If this fails, the
   reverse cutover would get stuck half way, with Singapore fenced and Sydney unable to serve:
   ```
   scripts/check-app.sh ap-southeast-2 read
   ```

Many teams stop here: the region that took over stays primary, and the other is the new
standby. To move the primary back to Sydney, continue, in a quiet period:

6. Run "Fail over" above in the other direction (swap the two region names in every
   command): fence Singapore, verify, record its final position, close the door, wait for
   Sydney to replay past it, promote Sydney, verify a write in Sydney, move the traffic.
7. Bring Terraform in line for Sydney ("Afterwards" above, with the region names swapped).
8. **Rebuild Singapore as the replica, in two separate applies.** Singapore's instance has
   deletion protection on, and RDS refuses to delete a protected instance, so Terraform
   cannot replace it in one go:

   - First apply: in `envs/ap-southeast-1/15-database.tfvars` set only
     `deletion_protection = false`. The plan is an update in place. Do this only after
     step 6's write check has passed in Sydney: from here Singapore's copy can be deleted.
   - Second apply: set `primary_region = "ap-southeast-2"` and `fenced = false`. The plan
     replaces Singapore's instance with a replica of Sydney.

9. Give Singapore's backend the credentials and check it, as in steps 4 and 5, for
   `ap-southeast-1`.

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
hand: about 45 minutes later it serves the application at the version Git says. That is the
strongest disaster recovery claim an infrastructure-as-code platform can make.
