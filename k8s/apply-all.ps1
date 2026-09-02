# Deploy completo no cluster K8s local (Docker Desktop, Kind, Minikube...).
# Rode da raiz do repositorio: .\fcg-orchestration\k8s\apply-all.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))

# Etapa 0: o KEDA e um operador de cluster, nao um componente da aplicacao. Vive
# no proprio namespace, e instalado uma unica vez e sobrevive a exclusao do
# namespace fcg. Os CRDs precisam estar registrados antes de qualquer
# ScaledObject ser aplicado, senao o kubectl apply falha.
$kedaVersion = '2.20.2'
Write-Host "==> KEDA (pre-requisito de cluster)" -ForegroundColor Cyan
if (-not (kubectl get namespace keda --ignore-not-found)) {
    kubectl apply --server-side -f "https://github.com/kedacore/keda/releases/download/v$kedaVersion/keda-$kedaVersion.yaml"
} else {
    Write-Host "    ja instalado"
}
kubectl wait --for condition=established --timeout=90s crd/scaledobjects.keda.sh crd/triggerauthentications.keda.sh
kubectl wait --for=condition=ready pod -l app=keda-operator -n keda --timeout=180s
kubectl label    namespace keda app.kubernetes.io/part-of=fcg --overwrite | Out-Null
kubectl annotate namespace keda fcg.io/role="Autoescala da funcao serverless de notificacoes (Fase 3)" --overwrite | Out-Null

Write-Host "==> Namespace + infra (postgres + rabbitmq)" -ForegroundColor Cyan
kubectl apply -f "$root/fcg-orchestration/k8s/namespace.yaml"
kubectl apply -f "$root/fcg-orchestration/k8s/infra/"

Write-Host "==> Aguardando Postgres ficar Ready..." -ForegroundColor Cyan
kubectl wait --for=condition=ready pod -l app=postgres -n fcg --timeout=180s

Write-Host "==> Aguardando RabbitMQ ficar Ready..." -ForegroundColor Cyan
kubectl wait --for=condition=ready pod -l app=rabbitmq -n fcg --timeout=180s

Write-Host "==> Aguardando MongoDB ficar Ready..." -ForegroundColor Cyan
kubectl wait --for=condition=ready pod -l app=mongodb -n fcg --timeout=180s

Write-Host "==> Aguardando Redis ficar Ready..." -ForegroundColor Cyan
kubectl wait --for=condition=ready pod -l app=redis -n fcg --timeout=120s

Write-Host "==> Stack de observabilidade (Prometheus + Grafana)" -ForegroundColor Cyan
kubectl apply -f "$root/fcg-orchestration/k8s/monitoring/"

Write-Host "==> API Gateway (Kong)" -ForegroundColor Cyan
kubectl apply -f "$root/fcg-orchestration/k8s/gateway/"

Write-Host "==> Microsservicos" -ForegroundColor Cyan
kubectl apply -f "$root/fcg-users-api/k8s/"
kubectl apply -f "$root/fcg-catalog-api/k8s/"
kubectl apply -f "$root/fcg-payments-api/k8s/"

# A NotificationsAPI foi substituida pela funcao serverless. Nao ha wait aqui:
# zero replicas e o estado correto em ociosidade, e um kubectl wait de pod
# ficaria travado ate o timeout. A verificacao certa e o ScaledObject.
Write-Host "==> Funcao serverless de notificacoes" -ForegroundColor Cyan
kubectl apply -f "$root/fcg-notifications-fn/k8s/"

Write-Host "==> Status atual:" -ForegroundColor Cyan
kubectl get pods,svc -n fcg

Write-Host ""
Write-Host "[OK] Deploy concluido." -ForegroundColor Green
Write-Host ""
Write-Host "  Porta de entrada unica do sistema (gateway):" -ForegroundColor Green
Write-Host "    http://localhost:8000/users/...     e     http://localhost:8000/catalog/..."
Write-Host ""
Write-Host "  Ferramental interno (port-forward, um terminal por servico):"
Write-Host "    kubectl port-forward svc/rabbitmq     -n fcg 15672:15672"
Write-Host "    kubectl port-forward svc/grafana      -n fcg 3001:3000   # admin / fcg-grafana-admin"
Write-Host "    kubectl port-forward svc/prometheus   -n fcg 9090:9090"
