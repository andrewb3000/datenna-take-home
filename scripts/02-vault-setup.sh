#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="datenna"
VAULT_POD="vault-0"

vault_exec() {
  kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- env VAULT_TOKEN=root vault "$@"
}

vault_exec_stdin() {
  kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- env VAULT_TOKEN=root vault "$@"
}

echo "== Enabling kv-v2 at secret/ (harmless if already enabled in dev mode) =="
vault_exec secrets enable -path=secret kv-v2 || true

echo "== Enabling and configuring Kubernetes auth =="
vault_exec auth enable kubernetes || true
vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

echo "== Writing policies (one per workload, scoped to its own KV path) =="
vault_exec_stdin policy write postgres-policy - < "$REPO_ROOT/vault/postgres-policy.hcl"
vault_exec_stdin policy write minio-policy - < "$REPO_ROOT/vault/minio-policy.hcl"
vault_exec_stdin policy write app-policy - < "$REPO_ROOT/vault/app-policy.hcl"

echo "== Writing Kubernetes auth roles (binds each ServiceAccount to its policy) =="
vault_exec write auth/kubernetes/role/postgres \
  bound_service_account_names=postgres-sa \
  bound_service_account_namespaces="$NAMESPACE" \
  policies=postgres-policy ttl=1h
vault_exec write auth/kubernetes/role/minio \
  bound_service_account_names=minio-sa \
  bound_service_account_namespaces="$NAMESPACE" \
  policies=minio-policy ttl=1h
vault_exec write auth/kubernetes/role/app \
  bound_service_account_names=app-sa \
  bound_service_account_namespaces="$NAMESPACE" \
  policies=app-policy ttl=1h

echo "== Generating fresh credentials locally and writing them into Vault =="
# Each system's own admin/superuser credential (used only by that system's own
# bootstrap, and by scripts/03-deploy.sh to provision the app's scoped identity)
# is distinct from the credential the app itself is ever handed. The app never
# receives a copy of a superuser or root credential — see PG_APP_PASSWORD and
# MINIO_APP_ACCESS_KEY/SECRET_KEY below.
PG_SUPERUSER_PASSWORD=$(openssl rand -base64 24)
PG_APP_PASSWORD=$(openssl rand -base64 24)
MINIO_ROOT_USER=$(openssl rand -hex 8)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 24)
MINIO_APP_SECRET_KEY=$(openssl rand -base64 24)

vault_exec kv put secret/postgres \
  password="$PG_SUPERUSER_PASSWORD" \
  app_password="$PG_APP_PASSWORD"
vault_exec kv put secret/minio \
  root_user="$MINIO_ROOT_USER" root_password="$MINIO_ROOT_PASSWORD"
# minio_access_key is deliberately NOT stored here: like DB_USER, it's a stable
# identifier (k8s/01-configmap.yaml's MINIO_ACCESS_KEY="app"), not a secret. Only
# the secret key is Vault-managed and rotatable — verified empirically that MinIO's
# `mc admin user add` on an already-existing access key correctly rotates its
# secret in place (old secret stops authenticating, new one works) rather than
# erroring, so re-running this script never orphans old MinIO IAM users.
vault_exec kv put secret/app \
  db_password="$PG_APP_PASSWORD" \
  minio_secret_key="$MINIO_APP_SECRET_KEY"

unset PG_SUPERUSER_PASSWORD PG_APP_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD \
  MINIO_APP_SECRET_KEY

echo "== Vault configured: kv-v2 secrets, kubernetes auth, 3 policies, 3 roles =="
echo "   (Postgres's app_user role and MinIO's scoped IAM user are provisioned"
echo "   by scripts/03-deploy.sh, once each service is actually running.)"
