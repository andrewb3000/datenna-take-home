#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="datenna"

echo "== 1. No application credentials exist as native Kubernetes Secrets =="
kubectl -n "$NAMESPACE" get secrets
echo "(expect: only Vault/Kubernetes-internal secrets, if any — no postgres/minio/app credential objects)"
echo

echo "== 2. The credential is only readable from inside its own pod's filesystem =="
echo "-- app --"
kubectl -n "$NAMESPACE" exec deploy/app -- cat /vault/secrets/env
echo "-- postgres --"
kubectl -n "$NAMESPACE" exec deploy/postgres -- cat /vault/secrets/postgres-password; echo
echo

echo "== 3. Least privilege: the app's Vault identity cannot read minio's secret =="
APP_SA_TOKEN=$(kubectl -n "$NAMESPACE" exec deploy/app -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
APP_VAULT_TOKEN=$(kubectl -n "$NAMESPACE" exec vault-0 -- vault write -field=token auth/kubernetes/login role=app jwt="$APP_SA_TOKEN")
echo "-- app role reading secret/minio (expect: permission denied) --"
kubectl -n "$NAMESPACE" exec vault-0 -- env VAULT_TOKEN="$APP_VAULT_TOKEN" vault kv get secret/minio || true
echo "-- app role reading secret/app (expect: success) --"
kubectl -n "$NAMESPACE" exec vault-0 -- env VAULT_TOKEN="$APP_VAULT_TOKEN" vault kv get secret/app
echo

echo "== 4. Functional round trip: POST an item, GET it back through Postgres + MinIO =="
kubectl -n "$NAMESPACE" port-forward svc/app 8000:8000 >/tmp/datenna-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 2

RESP=$(curl -s -X POST localhost:8000/items -H 'Content-Type: application/json' -d '{"value":"hello from the demo"}')
echo "POST /items -> $RESP"
ID=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

echo "GET /items/$ID ->"
curl -s "localhost:8000/items/$ID"; echo
echo "GET /healthz ->"
curl -s "localhost:8000/healthz"; echo
