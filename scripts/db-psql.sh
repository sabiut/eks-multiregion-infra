#!/usr/bin/env bash
# Run one SQL statement against a region's database and print the result.
#
#   scripts/db-psql.sh ap-southeast-2 "SHOW default_transaction_read_only"
#   scripts/db-psql.sh ap-southeast-2 "SELECT pg_current_wal_lsn()"
#
# The database only accepts connections from the backend subnets, so this starts a
# short-lived pod on a backend node in that region's cluster, with the same connection
# details the backend uses (the Kubernetes Secret that External Secrets builds from Vault).
# No password appears on the command line or in this script. The pod is deleted afterwards.
#
# DRY_RUN=1 prints the pod's definition and starts nothing.
set -euo pipefail

region=${1:?usage: db-psql.sh <region> "<sql>"}
sql=${2:?usage: db-psql.sh <region> "<sql>"}
namespace=${NAMESPACE:-demo}
context=${KUBE_CONTEXT:-lab-$region}
secret=${DB_SECRET:-demo-api-vault}
name=db-psql-$(date +%s)-$RANDOM

# What runs in the pod. -A -t: the bare value only. ON_ERROR_STOP: a failed statement is a
# failed command. The SQL arrives in an environment variable, so quoting cannot break it.
# shellcheck disable=SC2016  # expanded inside the pod, not here
inner='PGPASSWORD="$DB_PASSWORD" psql -X -A -t -v ON_ERROR_STOP=1 "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=${PGSSLMODE:-require} connect_timeout=10" -c "$SQL"'

overrides=$(jq -n --arg name "$name" --arg sql "$sql" --arg secret "$secret" --arg inner "$inner" '{
  spec: {
    nodeSelector: {tier: "backend"},
    securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, seccompProfile: {type: "RuntimeDefault"}},
    containers: [{
      name: $name,
      image: "postgres:17-alpine",
      command: ["sh", "-c", $inner],
      env: [{name: "SQL", value: $sql}],
      envFrom: [{secretRef: {name: $secret}}],
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
    }]
  }
}')

if [[ ${DRY_RUN:-0} == 1 ]]; then
  echo "$overrides"
  exit 0
fi

kubectl --context "$context" -n "$namespace" run "$name" --image=postgres:17-alpine \
  --restart=Never --rm --attach --quiet --pod-running-timeout=3m --overrides="$overrides"
