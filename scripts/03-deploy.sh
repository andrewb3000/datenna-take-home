#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="datenna"
CLUSTER_NAME="datenna"

# Applies a manifest carrying Vault Agent Injector annotations, then checks that the
# injector's mutating webhook actually fired. On a fresh kind cluster there's a known
# race where the injector pod reports Ready before the API server's webhook client has
# picked it up, so a pod admitted in that window silently gets no init container. If
# that happens, delete the pod once and let the Deployment controller recreate it.
# Pinned to the newest pod by creation timestamp (not just "the first one returned") so
# this stays correct on a re-run/rolling update where an old, already-injected pod is
# still terminating alongside the new one.
apply_and_verify_injection() {
  local file="$1" label="$2"
  kubectl apply -f "$file"
  sleep 3
  local newest_pod
  newest_pod=$(kubectl -n "$NAMESPACE" get pod -l "$label" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | tail -n1)
  local injected
  injected=$(kubectl -n "$NAMESPACE" get pod "$newest_pod" \
    -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null | grep -c vault-agent-init || true)
  if [ "$injected" = "0" ]; then
    echo "Vault injection missed for '$label' (webhook race) — deleting pod, controller will recreate it"
    kubectl -n "$NAMESPACE" delete pod "$newest_pod" --ignore-not-found
    sleep 5
  fi
}

echo "== Applying non-secret config =="
kubectl apply -f "$REPO_ROOT/k8s/01-configmap.yaml"

echo "== Deploying Postgres =="
apply_and_verify_injection "$REPO_ROOT/k8s/10-postgres.yaml" app=postgres
kubectl -n "$NAMESPACE" rollout status deployment/postgres --timeout=120s

echo "== Deploying MinIO =="
apply_and_verify_injection "$REPO_ROOT/k8s/11-minio.yaml" app=minio
kubectl -n "$NAMESPACE" rollout status deployment/minio --timeout=120s

# Provisions a MinIO IAM user scoped to read/write on the 'items' bucket only, for the
# app to use — distinct from, and with no relationship to, the MinIO root credential.
# Runs once, using the root credential purely as a one-time bootstrap identity (the
# same trust level already used to configure Vault itself in 02-vault-setup.sh); the
# app pod itself never sees the root credential.
#
# The access key ("app") is a fixed, non-secret identifier — matching
# k8s/01-configmap.yaml's MINIO_ACCESS_KEY — not regenerated per run. Only the secret
# key is rotatable Vault-managed material. This is deliberate: verified empirically
# that `mc admin user add` on an already-existing access key correctly rotates its
# secret in place (confirmed old secret stops authenticating, new one works), so
# re-running this script with a freshly rotated secret in Vault never orphans old
# MinIO IAM users the way generating a new access key every run would have.
echo "== Provisioning a scoped MinIO IAM user for the app (not root) =="
MINIO_ROOT_USER=$(kubectl exec -n "$NAMESPACE" vault-0 -- env VAULT_TOKEN=root vault kv get -field=root_user secret/minio)
MINIO_ROOT_PASSWORD=$(kubectl exec -n "$NAMESPACE" vault-0 -- env VAULT_TOKEN=root vault kv get -field=root_password secret/minio)
MINIO_APP_SECRET_KEY=$(kubectl exec -n "$NAMESPACE" vault-0 -- env VAULT_TOKEN=root vault kv get -field=minio_secret_key secret/app)

kubectl exec -n "$NAMESPACE" deploy/minio -- mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
kubectl exec -n "$NAMESPACE" deploy/minio -- mc mb --ignore-existing local/items
kubectl exec -i -n "$NAMESPACE" deploy/minio -- mc admin policy create local items-rw /dev/stdin < "$REPO_ROOT/vault/minio-app-bucket-policy.json"
kubectl exec -n "$NAMESPACE" deploy/minio -- mc admin user add local app "$MINIO_APP_SECRET_KEY"
kubectl exec -n "$NAMESPACE" deploy/minio -- mc admin policy attach local items-rw --user app

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD MINIO_APP_SECRET_KEY

echo "== Building and loading the app image into kind (no registry needed) =="
docker build -t datenna-app:dev "$REPO_ROOT/app"
kind load docker-image datenna-app:dev --name "$CLUSTER_NAME"

echo "== Deploying app =="
apply_and_verify_injection "$REPO_ROOT/k8s/20-app.yaml" app=app
kubectl -n "$NAMESPACE" rollout status deployment/app --timeout=120s

echo "== All workloads deployed and ready =="
kubectl -n "$NAMESPACE" get pods
