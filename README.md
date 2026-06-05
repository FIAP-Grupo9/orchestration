> **Nota:** Esta e a copia independente do repositorio de **Orquestracao** gerada por split-repos.ps1. Para que docker-compose up e os manifestos K8s funcionem, clone os 5 repositorios lado-a-lado na mesma pasta-pai (fcg-users-api, fcg-catalog-api, fcg-payments-api, fcg-notifications-api, fcg-orchestration).

---

# Orchestration â€” FCG (Tech Challenge Fase 2)

Esta pasta contÃ©m **toda a infraestrutura compartilhada** dos quatro microsserviÃ§os (UsersAPI, CatalogAPI, PaymentsAPI, NotificationsAPI):

- `docker-compose.yml` â€” sobe Postgres + RabbitMQ + os 4 microsserviÃ§os
- `init/01-init-databases.sql` â€” inicializa Postgres com 3 bancos lÃ³gicos (`users_db`, `catalog_db`, `payments_db`) e 3 usuÃ¡rios isolados (boundary real entre serviÃ§os)
- `k8s/` â€” manifestos Kubernetes (Deployment, Service, ConfigMap, Secret) â€” ver subpastas
- `.env.example` â€” template para variÃ¡veis sensÃ­veis (JWT_SECRET)

---

## PrÃ©-requisitos

| Ferramenta | VersÃ£o mÃ­nima | ObservaÃ§Ã£o |
|---|---|---|
| Docker | 24+ | com `compose` v2 (`docker compose` ou `docker-compose`) |
| .NET SDK | 8.0 | apenas se for rodar/buildar fora de contÃªiner |
| kubectl | 1.28+ | para deploy K8s |
| Cluster K8s local | qualquer | Docker Desktop K8s, Kind, Minikube ou k3d |

---

## Rodar tudo com Docker Compose

```powershell
cd Orchestration
Copy-Item .env.example .env       # personalize o JWT_SECRET se quiser
docker compose up -d --build
docker compose ps                 # todos devem estar healthy/running
```

Portas expostas no host:
- `http://localhost:5001` â€” UsersAPI (Swagger em `/swagger`)
- `http://localhost:5002` â€” CatalogAPI (Swagger em `/swagger`)
- `http://localhost:5003` â€” PaymentsAPI (Swagger em `/swagger`)
- `http://localhost:5004` â€” NotificationsAPI (apenas health/metrics; Ã© consumer-only)
- `http://localhost:15672` â€” RabbitMQ Management UI (`guest`/`guest`)
- `localhost:5432` â€” Postgres (`postgres`/`postgres` para o superusuÃ¡rio; os serviÃ§os usam seus usuÃ¡rios scoped)

### Validar fluxo de cadastro (E2E)

```powershell
# 1) Registrar usuÃ¡rio
curl -X POST http://localhost:5001/api/auth/register `
  -H "Content-Type: application/json" `
  -d '{"name":"Anderson","email":"anderson@koester.com.br","password":"Senha@1234"}'

# 2) Conferir log da Notifications (deve mostrar "Welcome email to anderson@koester.com.br")
docker compose logs notifications-api --tail 20
```

### Validar fluxo de compra (E2E)

```powershell
# 1) Login para obter token
$body = '{"email":"anderson@koester.com.br","password":"Senha@1234"}'
$token = (curl -s -X POST http://localhost:5001/api/auth/login `
  -H "Content-Type: application/json" -d $body | ConvertFrom-Json).token

# 2) Como admin, criar um jogo no CatalogAPI (ajuste perfil do usuÃ¡rio primeiro)
# 3) Iniciar compra â†’ recebe 202 Accepted + orderId
curl -X POST http://localhost:5002/api/biblioteca `
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" `
  -d '{"jogoId":"<GAME-GUID>"}'

# 4) Conferir logs sequenciais
docker compose logs payments-api --tail 5            # Order processed: Approved
docker compose logs notifications-api --tail 5       # Purchase confirmation to <email>
docker compose logs catalog-api --tail 5             # Library updated for user <id>

# 5) Conferir biblioteca via GET
curl -H "Authorization: Bearer $token" http://localhost:5002/api/biblioteca
```

### Parar tudo

```powershell
docker compose down            # mantÃ©m o volume postgres_data
docker compose down -v         # remove TUDO inclusive dados do Postgres
```

---

## Deploy em Kubernetes

Os manifestos K8s estÃ£o divididos:

- `k8s/infra/` â€” Postgres + RabbitMQ (infraestrutura compartilhada)
- `../UsersAPI/k8s/`, `../CatalogAPI/k8s/`, `../PaymentsAPI/k8s/`, `../NotificationsAPI/k8s/` â€” um conjunto por serviÃ§o (`deployment.yaml`, `service.yaml`, `configmap.yaml`, `secret.yaml`)

### Ordem do deploy

```powershell
kubectl apply -f Orchestration/k8s/namespace.yaml
kubectl apply -f Orchestration/k8s/infra/

# Aguarde Postgres + RabbitMQ ficarem Ready
kubectl wait --for=condition=ready pod -l app=postgres -n fcg --timeout=120s
kubectl wait --for=condition=ready pod -l app=rabbitmq -n fcg --timeout=120s

kubectl apply -f UsersAPI/k8s/
kubectl apply -f CatalogAPI/k8s/
kubectl apply -f PaymentsAPI/k8s/
kubectl apply -f NotificationsAPI/k8s/

kubectl get pods -n fcg
```

Ou usar o script `apply-all.sh` (Linux/WSL) / `apply-all.ps1` (Windows).

### Acessar de fora do cluster

```powershell
kubectl port-forward svc/users-api    -n fcg 5001:8080
kubectl port-forward svc/catalog-api  -n fcg 5002:8080
kubectl port-forward svc/payments-api -n fcg 5003:8080
kubectl port-forward svc/rabbitmq     -n fcg 15672:15672
```

Os mesmos cURL acima funcionam, apenas substituindo o host.

---

## ComunicaÃ§Ã£o entre serviÃ§os

Dentro do cluster K8s, os serviÃ§os se comunicam pelos nomes de Service:
- `http://users-api:8080`, `http://catalog-api:8080`, `http://payments-api:8080`
- `amqp://rabbitmq:5672` (broker)
- `postgres:5432` (DB)

No `docker-compose`, os mesmos nomes de service funcionam (rede `fcg-net`).

---

## Troubleshooting

| Sintoma | Causa provÃ¡vel | Fix |
|---|---|---|
| `users-api` reinicia em loop com erro `password authentication failed for user "users_user"` | Volume `postgres_data` jÃ¡ tinha schema antigo; init SQL sÃ³ roda em volume vazio | `docker compose down -v && docker compose up -d --build` |
| `RabbitMQ.Client` erro `BrokerUnreachable` ao subir API | API iniciou antes do RabbitMQ ficar healthy | `depends_on.condition: service_healthy` jÃ¡ cobre â€” se persistir, aumentar retries do healthcheck |
| `JwtSettings:Secret must be at least 32 characters long` na inicializaÃ§Ã£o | `.env` nÃ£o foi criado ou JWT_SECRET muito curto | `Copy-Item .env.example .env` e abrir para conferir |
| Mensagem publicada nÃ£o chega ao consumer | Nomes de fila divergem entre publisher/consumer | Conferir tela "Queues" em `http://localhost:15672` |

---

## Trade-offs documentados

- **HS256 com chave simÃ©trica compartilhada via Secret K8s.** Em produÃ§Ã£o: migrar para RS256 com UsersAPI expondo JWKS endpoint.
- **Sem Outbox transacional.** IdempotÃªncia em 2 camadas: tabela `processed_messages` + unique index `(usuario_id, jogo_id)` em `biblioteca_jogos`. Janela de falha de ~ms entre commit do domÃ­nio e publish do evento aceita por escopo.
- **JWT sem revogaÃ§Ã£o.** UsuÃ¡rio deletado mantÃ©m token vÃ¡lido atÃ© expirar (8h). AceitÃ¡vel para escopo acadÃªmico.
- **Eventos "fat"** (carregam `UserEmail`, `GameName`). Evita HTTP sÃ­ncrono entre serviÃ§os; LGPD pediria payloads mais magros + lookups.
- **NotificationsAPI stateless.** Replay via RabbitMQ redelivery; sem tabela de auditoria.
- **1 Postgres / 3 bancos / 3 usuÃ¡rios.** Boundary real preservado (cada serviÃ§o sÃ³ vÃª seu banco). Em produÃ§Ã£o: instÃ¢ncias separadas.

