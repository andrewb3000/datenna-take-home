#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="datenna"
NAMESPACE="datenna"

echo "== Creating kind cluster '$CLUSTER_NAME' =="
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists, skipping create."
else
  kind create cluster --name "$CLUSTER_NAME"
fi

kubectl config use-context "kind-$CLUSTER_NAME"

echo "== Creating namespace =="
kubectl apply -f "$REPO_ROOT/k8s/00-namespace.yaml"

echo "== Installing Vault (server + Agent Injector, dev mode) via Helm =="
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null
helm repo update >/dev/null
helm upgrade --install vault hashicorp/vault \
  --namespace "$NAMESPACE" \
  --set "server.dev.enabled=true" \
  --wait --timeout=180s

echo "== Waiting for Vault Agent Injector rollout =="
kubectl -n "$NAMESPACE" rollout status deployment/vault-agent-injector --timeout=90s

echo "== Cluster + Vault ready =="
