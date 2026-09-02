> **Nota:** Esta é a cópia independente do repositório de **Orquestração**. Para que o deploy funcione, clone os repositórios lado a lado na mesma pasta-pai: `fcg-users-api`, `fcg-catalog-api`, `fcg-payments-api`, `fcg-notifications-fn`, `fcg-orchestration` (e `fcg-notifications-api`, mantido apenas como referência histórica).

---

# Orchestration — FCG (Tech Challenge)

Guia central do projeto: reúne a infraestrutura compartilhada, os manifestos de plataforma e as decisões de arquitetura.

## A arquitetura em uma olhada

```
                                 http://localhost:8000
                                          │
                                   ┌──────▼──────┐
                                   │  Kong       │  porta de entrada única
                                   │  (gateway)  │  valida o token JWT
                                   └──┬───────┬──┘
                          /users/…    │       │    /catalog/…
                            ┌─────────▼─┐   ┌─▼──────────┐
                            │ UsersAPI  │   │ CatalogAPI │
                            └─────┬─────┘   └──┬───┬───┬─┘
                                  │            │   │   │
                     PostgreSQL ──┴────────────┘   │   └── MongoDB (avaliações)
                                                   └────── Redis (cache)
                                  │
                            ┌─────▼──────────────────────┐
                            │  RabbitMQ (mensageria)      │
                            └──┬──────────────────────┬───┘
                               │                      │
                       ┌───────▼──────┐      ┌────────▼─────────┐
                       │ PaymentsAPI  │      │ Função serverless │  0 contêineres
                       └──────────────┘      │ (notificações)    │  quando ocioso
                                             └───────────────────┘
                         Prometheus + Grafana coletam métricas dos serviços
```

## Status

| Fase | Escopo | Status |
|---|---|---|
| Fase 2 | Microsserviços, mensageria e Kubernetes | ✅ Implementada |
| Fase 3 | Gateway, serverless, observabilidade, NoSQL e cache | ✅ Implementada e validada no cluster |

## Conteúdo deste repositório

| Item | Descrição |
|---|---|
| `k8s/infra/` | PostgreSQL, RabbitMQ (com a topologia de filas declarada), MongoDB e Redis |
| `k8s/gateway/` | Kong e sua configuração declarativa de rotas e segurança |
| `k8s/monitoring/` | Prometheus e Grafana, com painel provisionado |
| `k8s/apply-all.ps1` / `.sh` | Sobe o ambiente inteiro, na ordem correta |
| `docker-compose.yml` | Alternativa rápida, sem o ambiente completo (ver ressalva adiante) |
| `init/01-init-databases.sql` | Cria 3 bancos lógicos e 3 usuários isolados no PostgreSQL |

---

# Como subir o ambiente

## Pré-requisitos

| Ferramenta | Versão mínima | Observação |
|---|---|---|
| Docker | 24+ | com `compose` v2 |
| Cluster Kubernetes local | qualquer | Docker Desktop, Kind, Minikube ou k3d |
| kubectl | 1.28+ | |
| .NET SDK | 10.0 | apenas para compilar fora de contêiner |

> O KEDA **não** precisa ser instalado manualmente: o script de deploy o instala na primeira execução.

## 1. Construir as imagens

A partir da pasta-pai que contém todos os repositórios:

```powershell
docker build -t fcg-users-api:latest         .\fcg-users-api
docker build -t fcg-catalog-api:latest       .\fcg-catalog-api
docker build -t fcg-payments-api:latest      .\fcg-payments-api
docker build -t fcg-notifications-fn:latest  .\fcg-notifications-fn
```

> **Atenção ao atualizar código.** Se `kubectl get nodes` mostrar um nó chamado `desktop-control-plane`, o cluster guarda as imagens em um armazenamento separado do Docker do host e mantém em cache a versão antiga da tag `latest`. Nesse caso, refazer o `docker build` não basta: é preciso remover a imagem antiga de dentro do cluster antes de recriar os pods. O sintoma é um serviço que sobe saudável executando código velho.

## 2. Subir o ambiente

A ordem das etapas importa, e o motivo está explicado em cada uma:

| Etapa | O que sobe | Por que nesta posição |
|---|---|---|
| 0 | KEDA | É um operador de cluster, não parte da aplicação. Seus tipos precisam estar registrados antes da configuração de escala ser aplicada |
| 1 | namespace `fcg` | Tudo da aplicação vive dentro dele |
| 2 | PostgreSQL, RabbitMQ, MongoDB, Redis | As APIs não sobem sem eles — é preciso aguardar cada um ficar pronto |
| 3 | Prometheus e Grafana | Sem espera: passam a coletar quando os serviços aparecerem |
| 4 | Kong | Passa a ser a única porta de entrada |
| 5 | UsersAPI, CatalogAPI, PaymentsAPI | Já encontram a infraestrutura no ar |
| 6 | Função de notificações | Por último, e **sem espera** — não haver contêiner é o estado correto |

### 2.1. Deploy automatizado (recomendado)

```powershell
.\fcg-orchestration\k8s\apply-all.ps1     # Windows
./fcg-orchestration/k8s/apply-all.sh      # Linux/WSL
```

O script executa exatamente as etapas da tabela acima, com as esperas corretas entre elas.

### 2.2. Deploy manual, passo a passo

Se preferir entender cada etapa, ou precisar subir apenas parte do ambiente:

```powershell
# ── Etapa 0 ─ KEDA (uma única vez por cluster) ──────────────────────────────
# Pule esta etapa se `kubectl get ns keda` já responder: o KEDA sobrevive à
# exclusão do namespace da aplicação, então normalmente só é instalado uma vez.
#
# --server-side é necessário: os tipos do KEDA são grandes demais para o modo
# padrão do kubectl. Ao reaplicar sobre uma instalação existente, o comando
# imprime avisos de conflito de campo — são inofensivos.
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.20.2/keda-2.20.2.yaml

# Aguardar os tipos serem registrados. Sem isso, aplicar a configuração de escala
# na etapa 7 falha com "no matches for kind ScaledObject".
kubectl wait --for condition=established --timeout=90s crd/scaledobjects.keda.sh crd/triggerauthentications.keda.sh
kubectl wait --for=condition=ready pod -l app=keda-operator -n keda --timeout=180s

# Identificar o espaço como parte deste projeto (opcional, apenas organização)
kubectl label namespace keda app.kubernetes.io/part-of=fcg --overwrite

# ── Etapa 1 ─ Namespace da aplicação ────────────────────────────────────────
kubectl apply -f .\fcg-orchestration\k8s\namespace.yaml

# ── Etapa 2 ─ Bancos, cache e mensageria ────────────────────────────────────
# Inclui a estrutura de filas do RabbitMQ, declarada como configuração para que
# exista antes de qualquer serviço conectar.
kubectl apply -f .\fcg-orchestration\k8s\infra\

# ── Etapa 3 ─ Aguardar a infraestrutura ficar pronta ────────────────────────
kubectl wait --for=condition=ready pod -l app=postgres -n fcg --timeout=180s
kubectl wait --for=condition=ready pod -l app=rabbitmq -n fcg --timeout=180s
kubectl wait --for=condition=ready pod -l app=mongodb  -n fcg --timeout=180s
kubectl wait --for=condition=ready pod -l app=redis    -n fcg --timeout=120s

# ── Etapa 4 ─ Observabilidade ───────────────────────────────────────────────
kubectl apply -f .\fcg-orchestration\k8s\monitoring\

# ── Etapa 5 ─ API Gateway ───────────────────────────────────────────────────
kubectl apply -f .\fcg-orchestration\k8s\gateway\

# ── Etapa 6 ─ Microsserviços ────────────────────────────────────────────────
kubectl apply -f .\fcg-users-api\k8s\
kubectl apply -f .\fcg-catalog-api\k8s\
kubectl apply -f .\fcg-payments-api\k8s\

kubectl rollout status deployment/users-api    -n fcg --timeout=300s
kubectl rollout status deployment/catalog-api  -n fcg --timeout=300s
kubectl rollout status deployment/payments-api -n fcg --timeout=300s

# ── Etapa 7 ─ Função serverless de notificações ─────────────────────────────
kubectl apply -f .\fcg-notifications-fn\k8s\

# ── Conferência ─────────────────────────────────────────────────────────────
kubectl get pods -n fcg
kubectl get scaledobject -n fcg      # READY=True e ACTIVE=False
```

> **Não use `kubectl wait` na função de notificações.** Ela sobe com zero réplicas por design, então o comando ficaria travado até o tempo limite esperando um contêiner que não deve existir. A verificação correta é o `kubectl get scaledobject`.

Em Linux ou WSL, troque as barras invertidas dos caminhos por barras normais (`./fcg-orchestration/k8s/infra/`).

Do início ao fim, a sequência leva cerca de um minuto em um cluster local: a infraestrutura fica pronta em torno de 30 segundos e os serviços em mais 20.

### 2.3. Subir apenas parte do ambiente

As etapas são independentes depois que a infraestrutura está no ar. Por exemplo, para atualizar somente um serviço após alterar o código:

```powershell
docker build -t fcg-catalog-api:latest .\fcg-catalog-api
# (se o cluster mantiver a imagem antiga em cache, ver a ressalva da etapa 1)
kubectl rollout restart deployment/catalog-api -n fcg
kubectl rollout status  deployment/catalog-api -n fcg
```

## 3. Acessar

**Toda a aplicação entra por um endereço único:**

```
http://localhost:8000/users/...        http://localhost:8000/catalog/...
```

Ferramentas internas de operação ficam acessíveis apenas por `port-forward`, um terminal para cada:

```powershell
kubectl port-forward svc/grafana    -n fcg 3001:3000   # admin / fcg-grafana-admin
kubectl port-forward svc/prometheus -n fcg 9090:9090
kubectl port-forward svc/rabbitmq   -n fcg 15672:15672 # guest / guest
```

> O Grafana é publicado em **3001**, e não na 3000: essa porta costuma estar ocupada por outras ferramentas de desenvolvimento, e o conflito é silencioso — o `port-forward` reporta sucesso enquanto as requisições vão para o outro serviço.

## 4. O que já vem pronto

O ambiente sobe **pronto para uso**, sem nenhum passo manual:

| Item | Valor |
|---|---|
| Usuário administrador | `admin@fcg.com` / `Admin@1234` |
| Catálogo | 4 jogos cadastrados |

A carga inicial é controlada pela configuração `SeedData__Enabled`, ligada nos manifestos deste repositório e **desligada por padrão no código**. Ela nunca sobrescreve dados existentes: só age se o catálogo estiver vazio e se o administrador ainda não existir.

> Sem isso, um ambiente recém-criado subiria funcional mas vazio — e como não existe rota para promover alguém a administrador, o único caminho para cadastrar jogos seria alterar o banco de dados na mão.

## 5. Conferir que subiu

```powershell
kubectl get pods -n fcg
kubectl get scaledobject -n fcg    # deve mostrar READY=True e ACTIVE=False
```

> **Não estranhe a ausência de pods de notificação.** A função serverless só existe enquanto há mensagem para processar; zero contêineres em ociosidade é o comportamento correto, não uma falha.

---

# Testar o ambiente

## Fluxo completo, tudo pelo gateway

```powershell
$G = 'http://localhost:8000'
$json = @{'Content-Type'='application/json'}

# 0) Para as operações de administrador (cadastrar jogos e promoções),
#    use as credenciais que já vêm criadas:
#    admin@fcg.com / Admin@1234

# 1) Cadastro (rota pública)
Invoke-RestMethod "$G/users/api/auth/register" -Method Post -Headers $json `
  -Body '{"name":"Teste","email":"teste@fcg.com","password":"Senha@1234"}'

# 2) Login
$token = (Invoke-RestMethod "$G/users/api/auth/login" -Method Post -Headers $json `
  -Body '{"email":"teste@fcg.com","password":"Senha@1234"}').token
$auth = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

# 3) Catálogo (leitura pública)
$jogo = (Invoke-RestMethod "$G/catalog/api/jogos")[0]

# 4) Compra
Invoke-RestMethod "$G/catalog/api/biblioteca" -Method Post -Headers $auth `
  -Body (@{jogoId=$jogo.id} | ConvertTo-Json)

# 5) Biblioteca
Invoke-RestMethod "$G/catalog/api/biblioteca" -Headers $auth

# 6) Avaliação (MongoDB) — só é permitida para quem possui o jogo
Invoke-RestMethod "$G/catalog/api/jogos/$($jogo.id)/avaliacoes" -Method Post -Headers $auth `
  -Body '{"nota":5,"comentario":"Excelente!"}'
Invoke-RestMethod "$G/catalog/api/jogos/$($jogo.id)/avaliacoes/resumo"
```

## Segurança no gateway

```powershell
# Sem token, a requisição é barrada no gateway e nem chega à aplicação
Invoke-WebRequest "$G/catalog/api/biblioteca"          # 401

# Comprovação: nada aparece no log da CatalogAPI, e o 401 aparece no log do Kong
kubectl logs -n fcg -l app=kong --tail=5
```

## Cache (Redis)

```powershell
Invoke-RestMethod "$G/catalog/api/jogos" | Out-Null   # primeira chamada: vai ao banco
Invoke-RestMethod "$G/catalog/api/jogos" | Out-Null   # segunda: vem do cache
kubectl logs -n fcg -l app=catalog-api --tail=20 | Select-String 'Cache'
```

Editar um jogo descarta a cópia em cache, e a leitura seguinte já traz o dado novo.

## Função serverless (o ciclo liga/desliga)

```powershell
# Em um terminal, acompanhe os contêineres nascerem e morrerem:
kubectl get pods -n fcg -l app=notifications-fn -w

# Em outro, dispare um evento:
Invoke-RestMethod "$G/users/api/auth/register" -Method Post -Headers $json `
  -Body '{"name":"KEDA","email":"keda@fcg.com","password":"Senha@1234"}'

# O contêiner nasce em poucos segundos, processa e, após ~1 minuto sem
# mensagens, desaparece.
kubectl logs -n fcg -l app=notifications-fn --tail=20
```

## Observabilidade

Abra `http://localhost:3001` e o painel **FCG** já estará lá, sem nenhuma configuração. Gere tráfego e acompanhe em tempo real o tempo de resposta, o volume de requisições por serviço e por código HTTP, e a taxa de erros.

---

# Alternativa rápida — Docker Compose

```powershell
cd fcg-orchestration
Copy-Item .env.example .env
docker compose up -d --build
```

Sobe PostgreSQL, RabbitMQ, MongoDB, Redis e os três microsserviços nas portas 5001, 5002 e 5003.

**Ressalva importante:** o compose **não** inclui o gateway, a observabilidade nem a função serverless. O gateway e o monitoramento são exigidos pelo enunciado como manifestos Kubernetes, e a função depende do KEDA para escalar a partir de zero, o que só existe em Kubernetes. Sem a função, os eventos de notificação ficam acumulados nas filas — o que é esperado nesse modo. **Para o ambiente completo da Fase 3, use o deploy em Kubernetes.**

---

# Decisões técnicas — Fase 3

**Restrição de partida:** o grupo **não possui conta em nuvem** (AWS, Azure ou Google Cloud). Todas as decisões abaixo foram tomadas sob a exigência de que o ambiente completo funcione em um cluster Kubernetes local, sem serviços pagos.

| # | Atividade exigida pelo enunciado | Decisão | Onde fica |
|---|---|---|---|
| 1 | API Gateway | **Kong**, com configuração declarativa | `k8s/gateway/` |
| 2 | Migração para Serverless | **Azure Functions + KEDA**, no próprio cluster | repositório `fcg-notifications-fn` |
| 3 | Observabilidade | **Opção A** — Prometheus + Grafana | `k8s/monitoring/` |
| 4 | Persistência NoSQL | **MongoDB** — avaliações de jogos | `k8s/infra/` + `fcg-catalog-api` |
| 5 | Cache distribuído | **Redis** | `k8s/infra/` + `fcg-catalog-api` |

## 1. API Gateway — Kong

**O que foi decidido:** o Kong passa a ser a **única porta de entrada**. Todo tráfego externo chega por ele, que confere se a requisição traz um token válido e a encaminha ao serviço correto.

**Por que o Kong:** é a ferramenta recomendada pelo enunciado para Kubernetes e se instala por manifestos, que já é o padrão do repositório. Azure APIM e AWS API Gateway são opcionais no enunciado e exigiriam conta em nuvem.

**Por que sem banco de dados próprio:** o Kong pode guardar sua configuração em um banco ou em arquivo. Optamos pelo **arquivo versionado no Git** — que é exatamente o que o enunciado pede — de modo que não exista configuração fora do controle de versão.

**Decisões associadas:**

- **A validação do token acontece em dois lugares.** O gateway barra quem não apresenta token válido antes da requisição chegar aos serviços; ainda assim, cada serviço continua validando por conta própria, para não ficar desprotegido caso algo passe indevidamente.
- **As permissões continuam na aplicação.** O gateway confere se o token é autêntico; decidir o que cada perfil pode fazer permanece com os serviços.
- **As ferramentas internas não passam pelo gateway.** Grafana, Prometheus e o painel do RabbitMQ seguem acessíveis apenas de dentro do cluster, mantendo a superfície exposta ao mínimo.
- **Número fixo de processos de trabalho.** Por padrão o Kong cria um processo por núcleo de CPU da máquina. No cluster de teste, com 24 núcleos, isso esgotou a memória e derrubou o contêiner. Fixar o número também torna o manifesto previsível em qualquer máquina.

## 2. Serverless — Azure Functions com KEDA

**O que foi decidido:** o serviço de notificações deixou de ser um contêiner ligado 24 horas por dia e passou a ser uma **função**, que só existe enquanto há mensagem para processar — exatamente o desperdício que o enunciado aponta como problema.

**Como funciona sem nuvem:** o motor do Azure Functions é software de código aberto, distribuído como imagem de contêiner: a mesma que a Microsoft executa nos servidores dela. Nós a executamos no cluster local. Ao lado dela, o **KEDA** observa a fila de mensagens e ajusta a quantidade de contêineres — nenhum quando a fila está vazia, um (ou mais, sob carga) quando chegam mensagens, e nenhum de novo após o período ocioso.

Nenhuma mensagem se perde nesse processo: ela fica guardada na fila até que um contêiner nasça para processá-la.

**Por que não usar nuvem de verdade:** exigiria conta com cartão de crédito. Fica registrado como evolução futura — o mesmo código sobe na Azure sem reescrita.

**Por que não usar o LocalStack (emulador da AWS):** o LocalStack imita serviços da AWS, mas o coração do requisito é a função ser disparada pela nossa fila, que é RabbitMQ — e a AWS não oferece esse tipo de gatilho para funções. As saídas seriam trocar toda a mensageria por um serviço da AWS (retrabalho grande em algo que já funciona), criar um componente intermediário ligado o tempo todo (o que anularia o objetivo da fase) ou pagar pela versão comercial do emulador.

## 3. Observabilidade — Opção A: Prometheus + Grafana

> O enunciado exige que a escolha entre as opções A e B seja registrada neste README.

**O que foi decidido: a Opção A** — Prometheus e Grafana, ambos de código aberto e instalados no cluster por manifestos. O Prometheus coleta os números de funcionamento das aplicações; o Grafana os apresenta em painéis.

**Por que a Opção A e não a B (Datadog ou New Relic):**

- Não exige conta, cadastro nem chave de acesso em plataforma externa — coerente com a restrição de custo zero.
- A instalação por manifestos é o que o enunciado pede para esta opção e já é o padrão do repositório.
- Os painéis ficam versionados no Git, e não presos à conta de um fornecedor.

**O que os painéis mostram**, conforme exigido: tempo de resposta das requisições, quantidade de requisições (no total, por serviço e por código de resposta HTTP) e proporção de erros.

**Decisões associadas:**

- **Os serviços publicam seus próprios números** em um endereço interno que o Prometheus consulta periodicamente. A instrumentação ficou em código compartilhado, para não repetir o trabalho em cada serviço.
- **A descoberta é automática:** o Prometheus encontra os serviços por uma marcação nos contêineres, então incluir um serviço novo no monitoramento não exige alterar a configuração do Prometheus.
- **Os painéis sobem prontos**, sem nenhum passo manual.
- **O histórico de métricas fica guardado em disco**, com retenção de 7 dias. Sem isso, todo reinício do Prometheus — comum durante o desenvolvimento — apagaria o histórico e deixaria os painéis vazios.
- **O Grafana permanece sem armazenamento próprio**, porque todo o seu estado é reconstruído a cada inicialização. Alterações feitas pela interface não sobrevivem ao reinício: para mantê-las, exporte o painel e versione o arquivo.

## 4. Persistência NoSQL — MongoDB

**O que foi decidido:** MongoDB para um **sistema de avaliações de jogos** (nota e comentário), dentro da CatalogAPI.

**Por que MongoDB e não DynamoDB:** o DynamoDB é um serviço da AWS e exigiria conta em nuvem ou emulação. O MongoDB roda como contêiner local, sem custo.

**Por que avaliações:** o enunciado cita quatro possibilidades como exemplos alternativos — catálogo expandido, registros de eventos, perfis de usuário **ou** sistema de avaliações — então um cenário bem implementado atende ao requisito. As avaliações foram escolhidas por serem o melhor caso de uso: o conteúdo é naturalmente flexível (um comentário livre não cabe bem em uma tabela rígida), o volume tende a crescer bastante e não há necessidade de tratamento transacional.

**O que caracteriza a persistência poliglota:** o PostgreSQL **continua responsável** pelos dados que exigem consistência rigorosa — jogos, biblioteca, promoções e pedidos. O MongoDB assume apenas os dados flexíveis. Não é substituição de um banco pelo outro, e sim cada informação armazenada no banco mais adequado ao seu formato.

## 5. Cache distribuído — Redis

**O que foi decidido:** Redis para guardar temporariamente os resultados das consultas mais repetidas da CatalogAPI — a listagem do catálogo e as promoções em vigor.

**Por que:** são consultas feitas com muita frequência que devolvem sempre o mesmo resultado entre uma alteração e outra. Guardando a resposta pronta em memória, o sistema responde mais rápido e o banco recebe muito menos carga. Na validação, a mesma consulta caiu de **584 ms para 17 ms**.

**Decisões associadas:**

- **A informação guardada é apagada assim que muda.** Criar, alterar ou remover um jogo ou promoção descarta a cópia temporária, evitando exibir dados desatualizados. Há também um prazo de validade de 5 minutos como segurança adicional.
- **O Redis não guarda nada em disco.** São cópias temporárias: perdê-las apenas faz o sistema consultar o banco e preencher o cache de novo.
- **Uma falha do Redis não derruba a aplicação:** o acesso ao cache é tolerante a erro e a consulta segue para o banco.

## 6. Decisões de apoio

Ajustes que não correspondem a uma atividade do enunciado, mas foram necessários para viabilizá-las.

### 6.1. Cada serviço passou a ter suas próprias filas

CatalogAPI e NotificationsAPI compartilhavam a mesma fila de mensagens de pagamento. Como uma mensagem só é entregue a um destinatário por fila, cada compra ora atualizava a biblioteca do usuário, ora enviava o e-mail de confirmação — raramente as duas coisas de forma confiável.

**Decisão:** separar as filas por serviço, garantindo que cada um receba sua própria cópia de cada mensagem. A correção era pré-requisito da migração para serverless, pois a função herdaria o mesmo problema.

### 6.2. As filas passaram a ser criadas como configuração

Até a Fase 2, as filas eram criadas pelos serviços ao iniciarem. Com a NotificationsAPI substituída pela função, ninguém mais as criaria — e isso causaria duas falhas silenciosas: o KEDA consultaria uma fila inexistente e nunca ligaria a função, e as mensagens publicadas seriam descartadas sem erro algum.

**Decisão:** declarar a estrutura de filas em arquivo versionado, carregado pelo RabbitMQ ao iniciar. Assim ela existe independentemente de qual serviço subiu primeiro, e o ambiente pode ser recriado do zero de forma previsível. Validado apagando o volume do RabbitMQ: o broker sobe com todas as filas prontas antes de qualquer serviço conectar.

### 6.3. O KEDA fica em espaço próprio

O KEDA é uma **ferramenta de plataforma**, não parte da aplicação — comparável a um componente de infraestrutura do Kubernetes. É instalado uma única vez no cluster e permanece funcionando independentemente da aplicação estar no ar.

**Decisão:** mantê-lo em espaço separado do da aplicação. Isso preserva uma propriedade importante do dia a dia: é possível apagar e recriar todo o ambiente da aplicação sem afetá-lo. Se dividisse o mesmo espaço, apagar a aplicação deixaria pedaços quebrados pelo cluster. Para deixar claro que pertence a este projeto, o espaço recebe uma etiqueta de identificação.

---

# Troubleshooting

| Sintoma | Causa provável | Resolução |
|---|---|---|
| Um serviço sobe saudável mas executa **código antigo** após alterações | O cluster mantém em cache a versão anterior da imagem | Remover a imagem antiga de dentro do cluster antes de recriar os pods (ver a ressalva na etapa 1) |
| `password authentication failed for user "users_user"` | O volume do PostgreSQL já tinha estrutura antiga; o script de inicialização só roda em volume vazio | Apagar o volume e subir novamente |
| Erro de conexão com o RabbitMQ ao subir uma API | A API iniciou antes do broker ficar pronto | Já coberto pelas verificações de dependência; se persistir, aumentar as tentativas |
| **Nenhum contêiner de notificação aparece** | Nenhuma — é o comportamento correto quando não há mensagens | Confirmar com `kubectl get scaledobject -n fcg`: `READY=True` significa saudável |
| A compra atualiza a biblioteca **ou** envia o e-mail, alternando entre execuções | Serviços compartilhando a mesma fila | Conferir se existem filas separadas por serviço (decisão 6.1) |
| O cadastro funciona, mas a função nunca é acionada e a fila está vazia | As filas não foram criadas previamente e as mensagens estão sendo descartadas | Conferir a estrutura de filas declarada (decisão 6.2) |
| `no matches for kind "ScaledObject"` ao aplicar os manifestos | O KEDA ainda não terminou de instalar | Aguardar e repetir; o script de deploy já faz essa espera |
| O Grafana abre mas mostra outra aplicação, ou recusa a senha | A porta 3000 já estava ocupada por outra ferramenta; o `port-forward` reporta sucesso mesmo assim | Usar a porta 3001. Para confirmar que é o Grafana certo, `http://localhost:3001/api/health` deve responder com `database` e `version` |
| Requisição com token válido recusada pelo gateway | Divergência entre a configuração de token do gateway e a dos serviços | Conferir os dados do emissor do token nos dois lados |

Comandos úteis:

```powershell
kubectl get events -n fcg --sort-by='.lastTimestamp' | Select-Object -Last 30
kubectl describe pod <nome-do-pod> -n fcg
kubectl logs -n fcg -l app=users-api --tail=100 --follow
kubectl exec -n fcg deploy/rabbitmq -- rabbitmqctl list_queues name messages consumers
```

# Parar e limpar

### Pausar sem perder nada

Desliga os contêineres mantendo dados, configuração e o ambiente montado. Útil para liberar recursos da máquina entre sessões de trabalho:

```powershell
kubectl scale deployment --all -n fcg --replicas=0
```

Para religar, basta reaplicar os manifestos (etapas 4 a 7) ou rodar o `apply-all` novamente — as réplicas voltam aos valores dos manifestos.

> A função de notificações já fica em zero por natureza; o KEDA continua cuidando dela.

### Remover apenas os microsserviços

Mantém bancos, mensageria e os dados:

```powershell
kubectl delete -f .\fcg-users-api\k8s\
kubectl delete -f .\fcg-catalog-api\k8s\
kubectl delete -f .\fcg-payments-api\k8s\
kubectl delete -f .\fcg-notifications-fn\k8s\
```

### Remover tudo

```powershell
kubectl delete namespace fcg      # apaga a aplicação inteira, inclusive os dados
```

O KEDA **sobrevive** a esse comando, intencionalmente: ele é do cluster, não da aplicação. Na próxima subida, a etapa 0 pode ser pulada.

Para remover também o KEDA, o que raramente é necessário:

```powershell
kubectl delete -f https://github.com/kedacore/keda/releases/download/v2.20.2/keda-2.20.2.yaml
```

---

# Trade-offs documentados

## Herdados da Fase 2

- **Chave de assinatura de token compartilhada entre os serviços.** Em produção, o caminho seria uma chave pública publicada pela UsersAPI, evitando segredo compartilhado.
- **Sem Outbox transacional.** A proteção contra duplicidade é feita em duas camadas (registro de mensagens já processadas e restrição de unicidade no banco). Existe uma janela de milissegundos de risco, aceita pelo escopo.
- **Token sem revogação.** Um usuário excluído mantém o token válido até ele expirar (8 horas).
- **Eventos carregam dados redundantes** (e-mail e nome do jogo). Evita chamadas síncronas entre serviços; a LGPD pediria conteúdos mais enxutos.
- **Um PostgreSQL com 3 bancos e 3 usuários.** A separação entre serviços é real (cada um só enxerga o próprio banco). Em produção, seriam instâncias separadas.
- **Segredos em texto puro nos manifestos.** São valores fictícios, para o desafio acadêmico. Em produção, usar cofre de segredos.

## Assumidos na Fase 3

- **Sem fila de mensagens com erro permanente.** Uma mensagem defeituosa é reentregue indefinidamente; produção teria um destino separado para esses casos.
- **Tempos de reação do escalonamento reduzidos** para tornar o ciclo liga/desliga visível em uma demonstração. Em produção, valores maiores evitariam oscilação.
- **Alguns segundos de espera** entre a mensagem chegar e ser processada, por conta da criação do contêiner. É característica do modelo serverless e aceitável para notificações.
- **Retenção de 7 dias para as métricas.** Produção guardaria por mais tempo, em armazenamento dedicado.
- **Nomes de fila funcionam como contrato**, declarados tanto na configuração do RabbitMQ quanto no código dos serviços; divergir os nomes interrompe o fluxo de mensagens de forma silenciosa.
- **A função roda em .NET 8**, e não na versão 10 dos microsserviços, porque o motor do Azure Functions ainda não a suporta. São processos independentes, sem binários compartilhados.
- **O `docker-compose` não cobre o ambiente completo** (ver ressalva na seção correspondente).
