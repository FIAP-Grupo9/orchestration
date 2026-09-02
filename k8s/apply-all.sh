#!/usr/bin/env bash
# Deploy completo no cluster K8s local (Docker Desktop, Kind, Minikube...).
# Rode da raiz do repositório: ./fcg-orchestration/k8s/apply-all.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Etapa 0: o KEDA é um operador de cluster, não um componente da aplicação. Vive
# no próprio namespace, é instalado uma única vez e sobrevive à exclusão do
# namespace fcg. Os CRDs precisam estar registrados antes de qualquer
# ScaledObject ser aplicado, senão o kubectl apply falha.
KEDA_VERSION=2.20.2
echo "==> KEDA (pré-requisito de cluster)"
if ! kubectl get namespace keda >/dev/null 2>&1; then
  kubectl apply --server-side -f "https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
else
  echo "    já instalado"
fi
kubectl wait --for condition=established --timeout=90s crd/scaledobjects.keda.sh crd/triggerauthentications.keda.sh
kubectl wait --for=condition=ready pod -l app=keda-operator -n keda --timeout=180s
kubectl label    namespace keda app.kubernetes.io/part-of=fcg --overwrite >/dev/null
kubectl annotate namespace keda fcg.io/role="Autoescala da funcao serverless de notificacoes (Fase 3)" --overwrite >/dev/null

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

# A NotificationsAPI foi substituída pela função serverless. Não há wait aqui:
# zero réplicas é o estado correto em ociosidade, e um kubectl wait de pod
# ficaria travado até o timeout. A verificação certa é o ScaledObject.
echo "==> Função serverless de notificações"
kubectl apply -f "$ROOT/fcg-notifications-fn/k8s/"

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
