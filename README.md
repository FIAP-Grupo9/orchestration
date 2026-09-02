> **Nota:** Esta é a cópia independente do repositório de **Orquestração**. Para que `docker compose up` e os manifestos K8s funcionem, clone os repositórios lado a lado na mesma pasta-pai (`fcg-users-api`, `fcg-catalog-api`, `fcg-payments-api`, `fcg-notifications-api`, `fcg-orchestration` e, a partir da Fase 3, `fcg-notifications-fn`).

---

# Orchestration — FCG (Tech Challenge)

Este repositório é o **guia central** do projeto: reúne a infraestrutura compartilhada, os manifestos de plataforma e as decisões de arquitetura tomadas em cada fase.

| Item | Descrição |
|---|---|
| `docker-compose.yml` | Sobe Postgres + RabbitMQ + os microsserviços |
| `init/01-init-databases.sql` | Cria no Postgres 3 bancos lógicos (`users_db`, `catalog_db`, `payments_db`) e 3 usuários isolados — cada serviço só enxerga o próprio banco |
| `k8s/` | Manifestos Kubernetes (Deployment, Service, ConfigMap, Secret) |
| `.env.example` | Template para variáveis sensíveis (JWT_SECRET) |

## Status das fases

| Fase | Escopo | Status |
|---|---|---|
| Fase 2 | Microsserviços, mensageria e Kubernetes | ✅ Implementada — é o que as seções operacionais abaixo descrevem |
| Fase 3 | Gateway, serverless, observabilidade, NoSQL e cache | 📋 Planejada — decisões registradas na segunda metade deste documento |

---

## Pré-requisitos

| Ferramenta | Versão mínima | Observação |
|---|---|---|
| Docker | 24+ | com `compose` v2 (`docker compose`) |
| .NET SDK | 10.0 | apenas se for rodar/compilar fora de contêiner |
| kubectl | 1.28+ | para deploy no Kubernetes |
| Cluster Kubernetes local | qualquer | Docker Desktop, Kind, Minikube ou k3d |
| KEDA | 2.15+ | **a partir da Fase 3** — instalado uma vez por cluster (ver decisão 6.3) |

---

## Rodar tudo com Docker Compose

```powershell
cd fcg-orchestration
Copy-Item .env.example .env       # personalize o JWT_SECRET se quiser
docker compose up -d --build
docker compose ps                 # todos devem estar healthy/running
```

Portas expostas no host:

- `http://localhost:5001` — UsersAPI (Swagger em `/swagger`)
- `http://localhost:5002` — CatalogAPI (Swagger em `/swagger`)
- `http://localhost:5003` — PaymentsAPI (Swagger em `/swagger`)
- `http://localhost:5004` — NotificationsAPI (apenas health; é consumer-only)
- `http://localhost:15672` — RabbitMQ Management UI (`guest`/`guest`)
- `localhost:5432` — Postgres (`postgres`/`postgres` para o superusuário; os serviços usam usuários restritos)

### Validar o fluxo de cadastro

```powershell
# 1) Registrar usuário
curl -X POST http://localhost:5001/api/auth/register `
  -H "Content-Type: application/json" `
  -d '{"name":"Anderson","email":"anderson@koester.com.br","password":"Senha@1234"}'

# 2) Conferir o log da Notifications (deve exibir o e-mail de boas-vindas)
docker compose logs notifications-api --tail 20
```

### Validar o fluxo de compra

```powershell
# 1) Login para obter o token
$body = '{"email":"anderson@koester.com.br","password":"Senha@1234"}'
$token = (curl -s -X POST http://localhost:5001/api/auth/login `
  -H "Content-Type: application/json" -d $body | ConvertFrom-Json).token

# 2) Como admin, criar um jogo no CatalogAPI (ajuste o perfil do usuário primeiro)
# 3) Iniciar a compra → recebe 202 Accepted + orderId
curl -X POST http://localhost:5002/api/biblioteca `
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" `
  -d '{"jogoId":"<GAME-GUID>"}'

# 4) Acompanhar a cadeia de eventos nos logs
docker compose logs payments-api --tail 5            # pagamento processado
docker compose logs notifications-api --tail 5       # e-mail de confirmação
docker compose logs catalog-api --tail 5             # biblioteca atualizada

# 5) Conferir a biblioteca
curl -H "Authorization: Bearer $token" http://localhost:5002/api/biblioteca
```

### Parar tudo

```powershell
docker compose down            # mantém o volume postgres_data
docker compose down -v         # remove tudo, inclusive os dados do Postgres
```

---

## Deploy em Kubernetes

Os manifestos estão divididos entre este repositório e os dos serviços:

- `k8s/infra/` — Postgres + RabbitMQ (infraestrutura compartilhada)
- `../fcg-users-api/k8s/`, `../fcg-catalog-api/k8s/`, `../fcg-payments-api/k8s/`, `../fcg-notifications-api/k8s/` — um conjunto por serviço (`deployment.yaml`, `service.yaml`, `configmap.yaml`, `secret.yaml`)

### Ordem do deploy

```powershell
kubectl apply -f fcg-orchestration/k8s/namespace.yaml
kubectl apply -f fcg-orchestration/k8s/infra/

# Aguardar Postgres e RabbitMQ ficarem prontos
kubectl wait --for=condition=ready pod -l app=postgres -n fcg --timeout=180s
kubectl wait --for=condition=ready pod -l app=rabbitmq -n fcg --timeout=180s

kubectl apply -f fcg-users-api/k8s/
kubectl apply -f fcg-catalog-api/k8s/
kubectl apply -f fcg-payments-api/k8s/
kubectl apply -f fcg-notifications-api/k8s/

kubectl get pods -n fcg
```

Ou usar o script `apply-all.ps1` (Windows) / `apply-all.sh` (Linux/WSL).

### Acessar de fora do cluster

```powershell
kubectl port-forward svc/users-api    -n fcg 5001:8080
kubectl port-forward svc/catalog-api  -n fcg 5002:8080
kubectl port-forward svc/payments-api -n fcg 5003:8080
kubectl port-forward svc/rabbitmq     -n fcg 15672:15672
```

Os mesmos comandos cURL das seções anteriores funcionam, apenas trocando o host.

> **A partir da Fase 3**, o acesso passa a ser feito por um endereço único (`http://localhost:8000`, através do gateway) e os port-forwards das APIs deixam de ser necessários. Eles permanecem apenas para as ferramentas internas de operação (RabbitMQ, Grafana e Prometheus).

---

## Comunicação entre serviços

Dentro do cluster, os serviços se comunicam pelos nomes de Service:

- `http://users-api:8080`, `http://catalog-api:8080`, `http://payments-api:8080`
- `amqp://rabbitmq:5672` (mensageria)
- `postgres:5432` (banco)

No `docker-compose`, os mesmos nomes funcionam através da rede `fcg-net`.

---

# Decisões técnicas — Fase 3

**Restrição de partida:** o grupo **não possui conta em nuvem** (AWS, Azure ou Google Cloud). Todas as decisões abaixo foram tomadas sob a exigência de que o ambiente completo funcione em um cluster Kubernetes local, sem serviços pagos.

| # | Atividade exigida pelo enunciado | Decisão | Onde fica |
|---|---|---|---|
| 1 | API Gateway | **Kong**, com configuração declarativa | `k8s/gateway/` (este repositório) |
| 2 | Migração para Serverless | **Azure Functions + KEDA**, executados no próprio cluster | repositório `fcg-notifications-fn` |
| 3 | Observabilidade | **Opção A** — Prometheus + Grafana | `k8s/monitoring/` (este repositório) |
| 4 | Persistência NoSQL | **MongoDB** — sistema de avaliações de jogos | `k8s/infra/` + `fcg-catalog-api` |
| 5 | Cache distribuído | **Redis** | `k8s/infra/` + `fcg-catalog-api` |

---

## 1. API Gateway — Kong

**O que foi decidido:** o Kong passa a ser a **única porta de entrada** do sistema. Todo o tráfego externo chega por ele, que confere se a requisição traz um token de autenticação válido e a encaminha ao serviço correto (UsersAPI ou CatalogAPI).

**Por que o Kong:** é a ferramenta recomendada pelo enunciado para ambientes Kubernetes e se instala por manifestos, que já é o padrão deste repositório. As alternativas (Azure APIM e AWS API Gateway) são opcionais no enunciado e exigiriam conta em nuvem.

**Por que sem banco de dados próprio:** o Kong pode guardar sua configuração em um banco ou em um arquivo. Optamos pelo **arquivo versionado no Git**. Assim, as rotas e políticas de segurança ficam registradas no repositório — que é exatamente o que o enunciado pede — e não existe configuração "escondida" fora do controle de versão.

**Decisões associadas:**

- **A validação do token acontece em dois lugares.** O gateway barra quem não apresenta um token válido, antes mesmo de a requisição chegar aos serviços. Ainda assim, cada serviço continua validando o token por conta própria — se algo passar pelo gateway indevidamente, a aplicação não fica desprotegida.
- **As permissões continuam na aplicação.** O gateway verifica se o token é autêntico; decidir *o que* cada perfil de usuário pode fazer (administrador ou usuário comum) permanece responsabilidade dos serviços.
- **As ferramentas internas não passam pelo gateway.** Grafana, Prometheus e o painel do RabbitMQ continuam acessíveis apenas de dentro do cluster. O gateway expõe somente o que é tráfego de negócio, mantendo a superfície exposta ao mínimo.

---

## 2. Migração para Serverless — Azure Functions com KEDA

**O que foi decidido:** o serviço de notificações deixa de ser um contêiner ligado 24 horas por dia e passa a ser uma **função**, que só existe enquanto há mensagem para processar. É exatamente o desperdício que o enunciado aponta como problema.

**Como isso funciona sem nuvem:** o motor do Azure Functions é software de código aberto, distribuído como imagem de contêiner — a mesma que a Microsoft executa nos servidores dela. Nós a executamos dentro do nosso cluster local. Ao lado dela trabalha o **KEDA**, uma ferramenta que fica observando a fila de mensagens e ajusta a quantidade de contêineres conforme a demanda:

- fila vazia → **nenhum contêiner de notificações rodando** (consumo zero de recursos);
- chegou mensagem → o KEDA cria o contêiner, que processa a mensagem;
- fila vazia novamente → o contêiner é desligado.

Nenhuma mensagem se perde nesse processo: ela fica guardada na fila até que um contêiner nasça para processá-la.

**Por que não usar nuvem de verdade:** exigiria conta com cartão de crédito. Fica registrado como evolução futura — o mesmo código sobe no Azure sem precisar ser reescrito.

**Por que não usar o LocalStack (emulador da AWS):** o LocalStack imita serviços da AWS, mas o coração do requisito é a função ser disparada pela nossa fila de mensagens, que é RabbitMQ — e a AWS não oferece esse tipo de gatilho para funções. As saídas seriam trocar toda a mensageria do projeto por um serviço da AWS (retrabalho grande em algo que já funciona), criar um componente intermediário ligado o tempo todo (o que anularia justamente o objetivo da fase) ou pagar pela versão comercial do emulador. A alternativa escolhida atende ao requisito sem nenhum desses custos e sem alterar uma linha dos serviços que publicam os eventos.

---

## 3. Observabilidade — Opção A: Prometheus + Grafana

> O enunciado exige que a escolha entre as opções A e B seja registrada neste README.

**O que foi decidido: a Opção A** — a dupla Prometheus e Grafana, ambos de código aberto e instalados no cluster por manifestos. O Prometheus coleta os números de funcionamento das aplicações; o Grafana os apresenta em painéis visuais.

**Por que a Opção A e não a B (Datadog ou New Relic):**

- Não exige conta, cadastro nem chave de acesso em plataforma externa — coerente com a restrição de custo zero do projeto.
- A instalação por manifestos Kubernetes é o que o enunciado pede para esta opção e já é o padrão do repositório.
- Os painéis ficam versionados no Git, e não presos à conta de um fornecedor.

**O que os painéis mostram**, conforme exigido pelo enunciado: o tempo de resposta das requisições, quantas requisições o sistema recebe (no total e separadas por tipo de resposta) e a proporção de erros.

**Decisões associadas:**

- **Os serviços passam a publicar seus próprios números.** UsersAPI, CatalogAPI e PaymentsAPI ganham um endereço interno de onde o Prometheus lê as informações periodicamente. A instrumentação foi feita em código compartilhado, para não repetir o trabalho em cada serviço.
- **Os painéis sobem prontos.** O Grafana é entregue já configurado, sem nenhum passo manual: ao abrir, o painel do projeto está lá.
- **O histórico de números fica guardado em disco.** Sem isso, toda vez que o Prometheus reiniciasse — algo comum durante o desenvolvimento — o histórico seria perdido e os painéis apareceriam vazios. O período de retenção é de 7 dias, suficiente para o escopo.
- **Acesso por port-forward**, apenas de dentro do cluster, com senha de administrador guardada como segredo do Kubernetes. O Grafana é publicado em **`localhost:3001`** e não na 3000: a porta 3000 costuma estar ocupada por outras ferramentas de desenvolvimento na máquina, e o conflito é silencioso — o `port-forward` reporta sucesso enquanto as requisições vão para o outro serviço. O Prometheus fica na 9090.

---

## 4. Persistência NoSQL — MongoDB

**O que foi decidido:** adotar o MongoDB para armazenar um **sistema de avaliações de jogos** (nota e comentário deixados pelos usuários), dentro da CatalogAPI.

**Por que MongoDB e não DynamoDB:** o DynamoDB é um serviço da AWS e exigiria conta em nuvem ou emulação. O MongoDB roda como contêiner no cluster local, sem custo.

**Por que avaliações:** o enunciado cita quatro possibilidades como exemplos alternativos — catálogo expandido, registros de eventos, perfis de usuário **ou** sistema de avaliações. Um cenário bem implementado atende ao requisito. As avaliações foram escolhidas por serem o melhor caso de uso: o conteúdo é naturalmente flexível (um comentário em texto livre não cabe bem em uma tabela rígida), o volume tende a crescer bastante, e não há necessidade de tratamento transacional.

**O que caracteriza a persistência poliglota:** o PostgreSQL **continua responsável** pelos dados que exigem consistência rigorosa — jogos, biblioteca do usuário, promoções e pedidos. O MongoDB assume apenas os dados flexíveis. Não é substituição de um banco pelo outro, e sim cada informação armazenada no banco mais adequado ao seu formato.

---

## 5. Cache distribuído — Redis

**O que foi decidido:** usar o Redis para guardar temporariamente os resultados das consultas mais repetidas da CatalogAPI — a listagem do catálogo de jogos e as promoções em vigor.

**Por que:** essas consultas são feitas com muita frequência e sempre devolvem o mesmo resultado entre uma alteração e outra. Guardando a resposta pronta em memória, o sistema responde mais rápido e o banco de dados recebe muito menos carga — que é o objetivo de desempenho apontado pelo enunciado.

**Decisões associadas:**

- **A informação guardada é apagada assim que muda.** Sempre que um jogo ou promoção é criado, alterado ou removido, a cópia temporária é descartada — evitando exibir dados desatualizados. Existe também um prazo de validade de 5 minutos como segurança adicional.
- **O Redis não guarda nada em disco.** Como se trata apenas de cópias temporárias, perder o conteúdo não causa problema: o sistema simplesmente volta a consultar o banco e a preencher o cache de novo.

---

## 6. Decisões de apoio

Ajustes que não correspondem a uma atividade do enunciado, mas foram necessários para viabilizá-las.

### 6.1. Cada serviço passa a ter suas próprias filas

Foi identificado que CatalogAPI e NotificationsAPI compartilhavam a mesma fila de mensagens de pagamento. Como uma mensagem só pode ser entregue a um destinatário por fila, uma compra ora atualizava a biblioteca do usuário, ora enviava o e-mail de confirmação — raramente as duas coisas de forma confiável.

**Decisão:** separar as filas por serviço, garantindo que cada um receba a sua própria cópia de cada mensagem. A correção precisa estar concluída antes da migração para serverless, pois a função herdaria o mesmo problema.

### 6.2. As filas passam a ser criadas como configuração

Até a Fase 2, as filas eram criadas automaticamente pelos serviços ao iniciarem. Como o serviço de notificações deixa de existir na Fase 3, ninguém mais criaria as filas que a função precisa consumir.

**Decisão:** declarar as filas em um arquivo de configuração versionado, carregado pelo RabbitMQ ao iniciar. Assim elas existem independentemente de qual serviço subiu primeiro, e o ambiente pode ser recriado do zero de forma previsível.

### 6.3. O KEDA é instalado uma vez por cluster, em espaço próprio

O KEDA é uma **ferramenta de plataforma**, não parte da aplicação — comparável a um componente de infraestrutura do Kubernetes. Ele é instalado uma única vez no cluster e permanece funcionando independentemente de a aplicação estar no ar ou não.

**Decisão:** mantê-lo em seu próprio espaço (namespace `keda`), separado do espaço da aplicação (`fcg`). Isso preserva uma propriedade importante do dia a dia: é possível apagar e recriar todo o ambiente da aplicação sem afetar o KEDA. Se ele dividisse o espaço com a aplicação, apagá-la deixaria pedaços quebrados pelo cluster.

Para deixar claro que ele pertence a este projeto, o espaço recebe uma etiqueta identificando o vínculo com o FCG.

### 6.4. Ordem de subida do ambiente

Nem todos os componentes sobem da mesma maneira:

| Etapa | Componente | Observação |
|---|---|---|
| 0 | KEDA | Instalado uma vez por cluster; aguardar ficar pronto |
| 1 | Espaço `fcg` | — |
| 2 | Postgres, RabbitMQ, MongoDB, Redis | Aguardar ficarem prontos: as APIs dependem deles |
| 3 | Prometheus e Grafana | Sem espera necessária |
| 4 | Kong (gateway) | — |
| 5 | UsersAPI, CatalogAPI, PaymentsAPI | Aguardar a publicação concluir |
| 6 | Função de notificações | **Sem espera** — não haver nenhum contêiner rodando é o estado correto |

> ⚠️ A última linha costuma confundir: a função serverless **não tem contêiner rodando** quando não há mensagens. Isso é o comportamento esperado, não uma falha. Para confirmar que está tudo certo, verifica-se a configuração de escalonamento, e não a existência de contêineres.

---

## Troubleshooting

| Sintoma | Causa provável | Resolução |
|---|---|---|
| `users-api` reinicia em loop com `password authentication failed for user "users_user"` | O volume do Postgres já tinha um schema antigo; o script de inicialização só roda em volume vazio | `docker compose down -v && docker compose up -d --build` (ou apagar o PVC, no Kubernetes) |
| Erro `BrokerUnreachable` ao subir uma API | A API iniciou antes de o RabbitMQ ficar pronto | Já coberto pelas verificações de dependência; se persistir, aumentar as tentativas do healthcheck |
| `JwtSettings:Secret must be at least 32 characters long` | O arquivo `.env` não foi criado ou o segredo é curto demais | `Copy-Item .env.example .env` e conferir o valor |
| Mensagem publicada não chega ao destino | Nomes de fila divergentes entre quem publica e quem consome | Conferir a aba **Queues** em http://localhost:15672 |
| **(Fase 3)** A compra atualiza a biblioteca **ou** envia o e-mail, alternando entre as execuções | Serviços compartilhando a mesma fila | Aplicar a separação de filas descrita na decisão 6.1 |
| **(Fase 3)** O cadastro funciona, mas a função de notificação nunca é acionada | As filas não foram criadas previamente | Conferir a configuração de filas descrita na decisão 6.2 |
| **(Fase 3)** Requisição com token válido é recusada pelo gateway | Divergência entre a configuração de token do gateway e a dos serviços | Conferir os dados do emissor do token nos dois lados |
| **(Fase 3)** O Grafana abre no navegador mas mostra outra aplicação, ou a API responde `Unauthorized` | A porta 3000 já estava ocupada por outra ferramenta na máquina; o `port-forward` reporta sucesso mesmo assim e o tráfego vai para o serviço errado | Usar a porta 3001 (`kubectl port-forward svc/grafana -n fcg 3001:3000`). Para confirmar que é o Grafana certo, `http://localhost:3001/api/health` deve responder com `database` e `version` |

Comandos úteis de diagnóstico:

```powershell
kubectl get events -n fcg --sort-by='.lastTimestamp' | Select-Object -Last 30
kubectl describe pod <nome-do-pod> -n fcg
kubectl logs -n fcg -l app=users-api --tail=100 --follow
kubectl exec -it -n fcg deploy/postgres -- psql -U postgres -c "\l"
```

---

## Trade-offs documentados (Fase 2)

- **Chave de assinatura de token compartilhada entre os serviços.** Em produção, o caminho seria uma chave pública publicada pela UsersAPI, evitando segredo compartilhado.
- **Sem Outbox transacional.** A proteção contra duplicidade é feita em duas camadas (registro de mensagens já processadas e restrição de unicidade no banco). Existe uma janela de milissegundos de risco, aceita pelo escopo.
- **Token sem revogação.** Um usuário excluído mantém o token válido até ele expirar (8 horas). Aceitável para o escopo acadêmico.
- **Eventos carregam dados redundantes** (e-mail e nome do jogo). Evita chamadas síncronas entre serviços; a LGPD pediria conteúdos mais enxutos.
- **NotificationsAPI sem estado.** Reprocessamento depende da reentrega pela mensageria; não há tabela de auditoria.
- **Um Postgres com 3 bancos e 3 usuários.** A separação entre serviços é real (cada um só enxerga o próprio banco). Em produção, seriam instâncias separadas.
- **Segredos em texto puro nos manifestos.** São valores fictícios, para o desafio acadêmico. Em produção, usar cofre de segredos.

## Trade-offs assumidos na Fase 3

- **Sem fila de mensagens com erro permanente.** Uma mensagem defeituosa é reentregue indefinidamente; produção teria um destino separado para esses casos.
- **Tempos de reação do escalonamento reduzidos** para tornar o ciclo "liga e desliga" visível na demonstração em vídeo. Em produção, valores maiores evitariam oscilação.
- **Alguns segundos de espera** entre a mensagem chegar e ser processada, por conta da criação do contêiner. É característica do modelo serverless e aceitável para notificações.
- **Retenção de 7 dias para os dados de monitoramento.** Produção guardaria por mais tempo, em armazenamento dedicado.
- **Nomes de fila funcionam como contrato.** Estão declarados tanto na configuração do RabbitMQ quanto no código dos serviços; divergir os nomes interrompe o fluxo de mensagens de forma silenciosa.
