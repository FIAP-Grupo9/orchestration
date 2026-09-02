# Deploy completo no cluster K8s local (Docker Desktop, Kind, Minikube...).
# Rode da raiz do repositorio: .\fcg-orchestration\k8s\apply-all.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))

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

Write-Host "==> Microsservicos" -ForegroundColor Cyan
kubectl apply -f "$root/fcg-users-api/k8s/"
kubectl apply -f "$root/fcg-catalog-api/k8s/"
kubectl apply -f "$root/fcg-payments-api/k8s/"
kubectl apply -f "$root/fcg-notifications-api/k8s/"

Write-Host "==> Status atual:" -ForegroundColor Cyan
kubectl get pods,svc -n fcg

Write-Host ""
Write-Host "[OK] Deploy concluido. Use port-forward para acessar:" -ForegroundColor Green
Write-Host "    kubectl port-forward svc/users-api    -n fcg 5001:8080"
Write-Host "    kubectl port-forward svc/catalog-api  -n fcg 5002:8080"
Write-Host "    kubectl port-forward svc/payments-api -n fcg 5003:8080"
Write-Host "    kubectl port-forward svc/rabbitmq     -n fcg 15672:15672"
Write-Host "    kubectl port-forward svc/grafana      -n fcg 3001:3000   # admin / fcg-grafana-admin"
Write-Host "    kubectl port-forward svc/prometheus   -n fcg 9090:9090"
