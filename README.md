# eks-multiregion-infra

Infrastructure for a two-region, three-tier platform on Amazon EKS. Terraform builds the AWS
side, Ansible configures each new cluster, and from then on Argo CD runs everything inside
the clusters from the GitOps repository.

A learning lab: small, cheap to run for an hour, and commented so each file explains itself.

## Three repositories, three jobs

| Repository | Holds | Its pipeline |
| --- | --- | --- |
| `eks-multiregion-infra` (this one) | Terraform and Ansible | plan on pull requests; deploy by hand, with an approval |
| `eks-multiregion-apps` | The application's source: frontend and backend | test, build once, scan, push images, ask for a dev release |
| `eks-multiregion-gitops` | Helm charts, cluster settings, and which version each environment runs | validate pull requests; promote dev to stg to prd |

No pipeline deploys to a cluster. Argo CD in each cluster reads the GitOps repository and
applies what it finds.

## Three tiers

```
                         internet
                            |
                    Global Accelerator            (Sydney; Singapore after a failover)
                            |
 +--------------------------|----------------------------------------- VPC, one per region --+
 |  public subnets     [ load balancer ]   [ NAT gateway ]                                   |
 |                          |                                                                |
 |  frontend subnets   [ frontend pods: nginx ]        private, on frontend nodes            |
 |                          |  /api/                                                         |
 |  backend subnets    [ backend pods: API ]           private, on backend nodes             |
 |                          |  5432                    (system nodes live here too)          |
 |  database subnets   [ RDS PostgreSQL ]              private, no route to the internet     |
 +-------------------------------------------------------------------------------------------+
```

Each tier accepts traffic only from the tier above it:

| From, to | What enforces it | Where |
| --- | --- | --- |
| Internet to load balancer | Only the public subnets have an internet gateway route | `modules/network` |
| Load balancer to frontend | NetworkPolicy: frontend pods accept the VPC's range only | GitOps: `charts/demo-web` |
| Frontend to backend | NetworkPolicy: backend pods accept frontend pods only | GitOps: `charts/demo-api` |
| Backend to database | Security group: port 5432 from the backend subnets' ranges only | `modules/database` |

A pod lands in its tier's subnets because its nodes do: nodes carry the label `tier`, the
workload has a matching `nodeSelector`, and the VPC CNI gives a pod an address from its
node's subnet. Sydney gets those nodes from Karpenter (one NodePool per tier), Singapore
from one managed node group per tier.

Sydney holds the primary database and takes all the traffic. Singapore is a warm standby: it
runs the application and holds a cross-region read replica, but is not registered with the
accelerator, so no user reaches it until the replica is promoted and a write is verified
([DR runbook](docs/dr-runbook.md)).

## Who does what

| Tool | Its job here | Why this tool |
| --- | --- | --- |
| Terraform | VPC and subnets, RDS database, EKS cluster, node groups, IAM roles, KMS key, S3 bucket, Global Accelerator | Creates cloud resources and remembers them in state, so it can change or remove them later |
| Ansible | Install Argo CD, create the root Application, initialise and configure Vault, pre-upgrade checks, drain before destroy | Ordered, repeatable steps against something that already exists |
| Argo CD | Every add-on and the application, from Git | Keeps the cluster matching Git continuously, not only when a pipeline runs |
| GitHub Actions | Runs Terraform and Ansible, with an approval before any change | No one applies from a laptop; every change is reviewed and logged |

The handoff between Terraform and Ansible is a pair of JSON files: after an apply, the pipeline
writes Terraform's outputs to JSON files under `ansible/.tfout/` (`scripts/handoff.sh`), and
Ansible's variables read them
(`ansible/inventories/group_vars/aws.yml`).

## Layout

```
bootstrap/               state bucket, image repositories, GitHub OIDC roles (once, from a laptop)
stacks/                  what gets applied. Each stack has its own state and is a short file
  10-network/            that calls modules: one region's network, four kinds of subnet
  15-database/           the database tier: RDS primary (Sydney) or read replica (Singapore)
  20-eks/                one cluster and the AWS resources its add-ons need
  30-global/             Global Accelerator in front of the live region
modules/                 the reusable Terraform the stacks call (see the table below)
envs/<region>/*.tfvars   what differs per region (CIDR, version, autoscaler)
scripts/tf.sh            runs one stack in one region, the same on a laptop and in CI
ansible/                 inventory, playbooks and roles
.github/workflows/       plan (pull requests), deploy (by hand), upgrade-precheck (by hand)
ci-equivalents/          the deploy pipeline as a Jenkinsfile, for comparison
docs/                    upgrade and disaster recovery runbooks
```

### Terraform modules

A module is a folder of Terraform with inputs (`variables.tf`) and outputs (`outputs.tf`),
written once and called wherever it is needed. A stack is a root that calls modules and owns
a state file. To follow the code, open a stack's `main.tf` first: it reads like a table of
contents, and each `module` block points at one folder below.

| Module | What it creates | Called by |
|---|---|---|
| `network` | VPC; public, frontend, backend and database subnets; NAT gateway; subnet tags | `stacks/10-network` |
| `database` | RDS PostgreSQL (primary or cross-region replica) and its security group | `stacks/15-database` |
| `eks-cluster` | Control plane, access entries, managed add-ons, system node group, optional node group per tier | `stacks/20-eks` |
| `karpenter` | Karpenter's IAM roles and interruption queue | `stacks/20-eks` (Karpenter clusters only) |
| `addon-identity` | Pod Identity IAM roles for the add-ons Argo CD installs | `stacks/20-eks` |
| `vault-unseal-key` | KMS key that lets Vault unseal itself | `stacks/20-eks` |
| `private-bucket` | Versioned, encrypted, private S3 bucket | `stacks/20-eks` (Velero backups), `bootstrap` (Terraform state) |
| `global-accelerator` | Accelerator, listener, one endpoint group per region | `stacks/30-global` |
| `image-repository` | ECR repository in each region | `bootstrap` (twice: frontend and backend images) |
| `github-oidc-role` | IAM role GitHub Actions assumes with OIDC | `bootstrap` (three times: plan, apply, publish) |

Three of these wrap community modules from the Terraform Registry (`terraform-aws-modules`
vpc, eks and eks-pod-identity), pinned to a version. The local module sets this project's
choices once, so the stack only passes what differs per cluster.

One stack, two regions: the Terraform code is the same for Sydney and Singapore. Only the
`.tfvars` file and the state file differ. Each region has its own state, so a mistake in one
cannot damage the other.

## First-time setup

1. Create the three repositories on GitHub and push them.
2. Bootstrap, once, from a laptop with admin credentials:

   ```
   cd bootstrap
   cp terraform.tfvars.example terraform.tfvars    # set your repository names
   terraform init && terraform apply
   terraform output github_secrets
   ```

3. In **this** repository on GitHub (Settings > Secrets and variables > Actions):
   - secrets `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`, `TF_STATE_BUCKET` from the output
   - secret `CLUSTER_ADMIN_ARN`: your own IAM user or role ARN, so you can use `kubectl`
   - variable `GITOPS_REPO_URL`: `https://github.com/<you>/eks-multiregion-gitops.git`
   - Settings > Environments: create `production` and add yourself as a required reviewer
4. In the **application** repository: secret `AWS_PUBLISH_ROLE_ARN` from the output.
5. Set up the release bot and the branch rule as described in the GitOps repository's README.
6. Push a change under `backend/` or `frontend/` in the application repository so its
   pipeline builds the first images, then promote that version through to prd in the GitOps
   repository.

## Build, in order

Actions > **deploy** > Run workflow:

| Step | target | action | Takes about |
| --- | --- | --- | --- |
| 1 | `ap-southeast-2` | `apply` | 35 minutes |
| 2 | `ap-southeast-1` | `apply` | 45 minutes |
| 3 | `global` | `apply` | 3 minutes |

Sydney first: Singapore's database is a replica of Sydney's. Each region runs four steps:
network, database, cluster, then Ansible. Step 3 registers Sydney only and needs its load
balancer to exist, so wait until `demo-web-prd` is healthy there
(`kubectl -n argocd get applications`).

## Remove, in order

`global` destroy, then Singapore, then Sydney (the replica before its primary). Type the
target name in `confirm_destroy`. Before Terraform removes a region, the workflow runs
`ansible/playbooks/drain.yml`, because the load balancer, Karpenter's instances and Vault's
volume were created by controllers in the cluster and Terraform does not know about them.

**Cost.** Two regions running cost very roughly 1.50 to 2 US dollars an hour (two EKS
control planes, the system and tier nodes, two NAT gateways, two load balancers, two small
RDS instances, the accelerator). This is an estimate, not a quote. Destroy when you finish.

## Try it without AWS

The cluster configuration also runs on a local [kind](https://kind.sigs.k8s.io) cluster: no
Terraform, no cost, no database (the backend counts in memory). Build and load both images
as described in the GitOps repository's `envs/local/release.yaml`, then here:

```
kind create cluster --name mr-local
cd ansible
pip install -r requirements.txt && ansible-galaxy collection install -r requirements.yml
GITOPS_REPO_URL=https://github.com/<you>/eks-multiregion-gitops.git \
  ansible-playbook playbooks/site.yml --limit local
```

Everything that is not AWS-specific works there: Argo CD, the app of apps, Vault, External
Secrets, canary and blue-green releases, the autoscaler for pods, pod security, RBAC, and
the NetworkPolicy between frontend and backend.

## Scripts

| Script | What it does |
| --- | --- |
| `scripts/tf.sh` | Runs one Terraform stack in one region, the same on a laptop and in the pipeline |
| `scripts/handoff.sh` | Writes Terraform's current outputs for Ansible |
| `scripts/check-app.sh` | Asks one region's application for a read or a write, and confirms which region answered |
| `scripts/db-psql.sh` | Runs one SQL statement against a region's database, from a short-lived pod |
| `scripts/drill-local.sh` | Rehearses the database part of the failover on two local PostgreSQL containers. No AWS, about a minute |

## Runbooks

- [Upgrading Kubernetes](docs/upgrade-runbook.md)
- [Disaster recovery and the failover drill](docs/dr-runbook.md)
