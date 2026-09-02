#!/usr/bin/env bash
# Deploy completo no cluster K8s local (Docker Desktop, Kind, Minikube...).
# Rode da raiz do repositório: ./fcg-orchestration/k8s/apply-all.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "==> Namespace + infra (postgres + rabbitmq)"
kubectl apply -f "$ROOT/fcg-orchestration/k8s/namespace.yaml"
kubectl apply -f "$ROOT/fcg-orchestration/k8s/infra/"

echo "==> Aguardando Postgres ficar Ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n fcg --timeout=180s

echo "==> Aguardando RabbitMQ ficar Ready..."
kubectl wait --for=condition=ready pod -l app=rabbitmq -n fcg --timeout=180s

echo "==> Aguardando MongoDB ficar Ready..."
kubectl wait --for=condition=ready pod -l app=mongodb -n fcg --timeout=180s

echo "==> Aguardando Redis ficar Ready..."
kubectl wait --for=condition=ready pod -l app=redis -n fcg --timeout=120s

echo "==> Stack de observabilidade (Prometheus + Grafana)"
kubectl apply -f "$ROOT/fcg-orchestration/k8s/monitoring/"

echo "==> API Gateway (Kong)"
kubectl apply -f "$ROOT/fcg-orchestration/k8s/gateway/"

echo "==> Microsserviços"
kubectl apply -f "$ROOT/fcg-users-api/k8s/"
kubectl apply -f "$ROOT/fcg-catalog-api/k8s/"
kubectl apply -f "$ROOT/fcg-payments-api/k8s/"
kubectl apply -f "$ROOT/fcg-notifications-api/k8s/"

echo "==> Status atual:"
kubectl get pods,svc -n fcg

cat <<EOF

✔  Deploy concluído.

  Porta de entrada única do sistema (gateway):
    http://localhost:8000/users/...     e     http://localhost:8000/catalog/...

  Ferramental interno (port-forward, um terminal por serviço):
    kubectl port-forward svc/rabbitmq     -n fcg 15672:15672
    kubectl port-forward svc/grafana      -n fcg 3001:3000   # admin / fcg-grafana-admin
    kubectl port-forward svc/prometheus   -n fcg 9090:9090
EOF
