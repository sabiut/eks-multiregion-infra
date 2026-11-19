# Runs inside the Vault pod (sent on standard input by roles/vault_config). VAULT_TOKEN is
# already exported. Each step checks first, so running it again changes nothing.
set -eu

# 1. A place to keep secrets: the key/value engine, version 2 (it keeps old versions).
if vault secrets list -format=json | grep -q '"secret/"'; then
  echo "OK       kv-v2 engine at secret/"
else
  vault secrets enable -path=secret kv-v2 >/dev/null
  echo "CHANGED  enabled kv-v2 engine at secret/"
fi

# 2. A way for pods to prove who they are: the Kubernetes auth method. A pod sends its
#    ServiceAccount token; Vault asks the Kubernetes API whether the token is genuine.
if vault auth list -format=json | grep -q '"kubernetes/"'; then
  echo "OK       kubernetes auth method"
else
  vault auth enable kubernetes >/dev/null
  echo "CHANGED  enabled kubernetes auth method"
fi
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc" >/dev/null

# 3. A policy: what a caller may do. This one can only read the demo application's secrets.
vault policy write demo-api - >/dev/null <<'POLICY'
path "secret/data/demo-api/*" {
  capabilities = ["read"]
}
POLICY
echo "OK       policy demo-api"

# 4. A role: ties an identity to a policy. Only the ServiceAccount demo-api (the backend) in
#    the application's namespaces gets the demo-api policy, and its Vault token lasts one
#    hour. The frontend has no role at all, so it cannot read any secret.
#    LAB: dev, stg and prd share this Vault and this secret. In production each environment
#    has its own Vault path, policy and database, so dev can never read production's password.
vault write auth/kubernetes/role/demo-api \
  bound_service_account_names=demo-api \
  bound_service_account_namespaces=demo,demo-dev,demo-stg \
  policies=demo-api \
  ttl=1h >/dev/null
echo "OK       role demo-api"

# 5. A secret for the demo, with a random value generated here so nothing is kept in Git.
if vault kv get secret/demo-api/config >/dev/null 2>&1; then
  echo "OK       secret demo-api/config"
else
  vault kv put secret/demo-api/config \
    API_KEY="$(head -c 24 /dev/urandom | base64)" \
    GREETING="hello from vault" >/dev/null
  echo "CHANGED  wrote secret demo-api/config"
fi

# 6. The database tier's connection details, when there is a database. Written on every run,
#    so a rotated master password reaches Vault (and from there the pods) by itself.
if [ -n "${DB_HOST:-}" ]; then
  vault kv patch secret/demo-api/config \
    DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_NAME="$DB_NAME" \
    DB_USER="$(echo "$DB_USER_B64" | base64 -d)" \
    DB_PASSWORD="$(echo "$DB_PASSWORD_B64" | base64 -d)" >/dev/null
  echo "OK       database connection details in demo-api/config"
fi
