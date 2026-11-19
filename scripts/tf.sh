#!/usr/bin/env bash
# Run Terraform for one stack in one region, the same way on a laptop and in the pipeline.
#
#   scripts/tf.sh plan    10-network ap-southeast-2
#   scripts/tf.sh apply   15-database ap-southeast-2
#   scripts/tf.sh apply   20-eks     ap-southeast-2
#   scripts/tf.sh output  20-eks     ap-southeast-2     # JSON, for Ansible
#   scripts/tf.sh destroy 20-eks     ap-southeast-2
#   scripts/tf.sh plan    30-global  global
#   PLAN_ONLY=1 scripts/tf.sh plan 20-eks ap-southeast-1   # before anything exists
#
# PLAN_ONLY=1 uses throwaway local state and placeholder inputs. It can only plan.
set -euo pipefail

action=${1:?usage: tf.sh <plan|apply|destroy|output> <stack> <region|global>}
stack=${2:?stack: 10-network, 15-database, 20-eks or 30-global}
region=${3:?region, or "global" for 30-global}
plan_only=${PLAN_ONLY:-0}

root=$(cd "$(dirname "$0")/.." && pwd)
dir=$root/stacks/$stack
varfile=$root/envs/$region/$stack.tfvars
key="$region/$stack.tfstate"
state_region=${TF_STATE_REGION:-ap-southeast-2}
[[ -d $dir ]] || { echo "no such stack: $stack" >&2; exit 1; }
[[ -f $varfile ]] || { echo "no variables file: $varfile" >&2; exit 1; }

args=(-var-file="$varfile")
# Extra cluster admins come from the environment, so no ARN is committed to a public repo.
if [[ $stack == 20-eks && -n ${CLUSTER_ADMIN_ARN:-} ]]; then
  args+=(-var="admin_principal_arns=[\"$CLUSTER_ADMIN_ARN\"]")
fi

cd "$dir"
if [[ $plan_only == 1 ]]; then
  [[ $action == plan ]] || { echo "PLAN_ONLY supports plan only" >&2; exit 1; }
  mkdir -p "$root/.planonly"
  printf 'terraform {\n  backend "local" { path = "%s" }\n}\n' "$root/.planonly/${key//\//-}" > backend_override.tf
  terraform init -input=false -reconfigure >/dev/null
else
  bucket=${TF_STATE_BUCKET:-eks-multiregion-tfstate-$(aws sts get-caller-identity --query Account --output text)}
  rm -f backend_override.tf
  terraform init -input=false -reconfigure \
    -backend-config="bucket=$bucket" \
    -backend-config="key=$key" \
    -backend-config="region=$state_region" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true" >/dev/null
  # These stacks read other stacks' outputs from the same bucket.
  if [[ $stack == 15-database || $stack == 20-eks ]]; then
    args+=(-var="state_bucket=$bucket" -var="state_region=$state_region")
  fi
fi

case $action in
  plan)    terraform plan -input=false "${args[@]}" ;;
  apply)   [[ ${CI:-} == true ]] && args+=(-auto-approve)
           terraform apply -input=false "${args[@]}" ;;
  destroy) [[ ${CI:-} == true ]] && args+=(-auto-approve)
           terraform destroy -input=false "${args[@]}" ;;
  output)  terraform output -json ;;
  *)       echo "unknown action: $action" >&2; exit 1 ;;
esac
