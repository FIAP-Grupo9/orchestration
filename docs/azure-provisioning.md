# Provisionamento da infraestrutura Azure (Fase 4)

Este documento registra como o ambiente de nuvem da Fase 4 foi provisionado, para
o caso de precisarmos recriá-lo do zero (ex.: fim do crédito, nova assinatura,
ou outro integrante do grupo reproduzindo o setup). Ele descreve a
**infraestrutura em si** (resource group, registry, cluster); o deploy da
aplicação dentro do cluster já está documentado no README deste repositório
(seção "Segredos e deploy da infra no AKS") e no `README.md` de cada serviço.

## Inventário (estado em que o ambiente foi entregue)

| Recurso | Nome | Detalhe |
|---|---|---|
| Resource group | `rg-fcg-techchallenge` | região `eastus` |
| Container Registry | `fcgtechchallengeacr` | SKU `Basic`, login server `fcgtechchallengeacr.azurecr.io` |
| AKS | `aks-fcg-techchallenge` | tier `Free`, Kubernetes `1.36`, rede `azure` (CNI) |
| Node pool | `nodepool1` | 2× `Standard_B2s` (burstable, 2 vCPU/4GB), disco de SO 128GB |
| Service Principal | `sp-fcg-github-actions` | `Contributor` escopado só a este resource group — usado pelo GitHub Actions (`AZURE_CREDENTIALS`) |

O AKS também gerencia automaticamente um segundo resource group,
`MC_rg-fcg-techchallenge_aks-fcg-techchallenge_eastus` — é onde ficam as VMs
dos nós, o disco, o Load Balancer e os IPs públicos. Não mexemos nele
diretamente; ele acompanha o ciclo de vida do cluster (ver seção de limpeza).

## Pré-requisitos

- Azure CLI instalada e autenticada: `az login`
- Uma subscription ativa (usamos Azure for Students)
- `kubectl` instalado

## Passo a passo para recriar do zero

```bash
# 0. Registrar os resource providers necessários (só na primeira vez da subscription)
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Network --wait
az provider register --namespace Microsoft.OperationsManagement --wait
az provider register --namespace Microsoft.OperationalInsights --wait

# 1. Resource group
az group create --name rg-fcg-techchallenge --location eastus

# 2. Container Registry (registry nativo exigido pelo edital)
az acr create --resource-group rg-fcg-techchallenge --name fcgtechchallengeacr --sku Basic

# 3. AKS — 2 nós burstable (baratos), tier gratuito de API
az aks create \
  --resource-group rg-fcg-techchallenge \
  --name aks-fcg-techchallenge \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --tier free \
  --generate-ssh-keys \
  --attach-acr fcgtechchallengeacr

# 4. Credenciais do kubectl
az aks get-credentials --resource-group rg-fcg-techchallenge --name aks-fcg-techchallenge --overwrite-existing

# 5. Service Principal para o GitHub Actions, escopado só a este resource group
#    (menor privilégio possível — não dá acesso ao resto da subscription)
RG_ID=$(az group show --name rg-fcg-techchallenge --query id -o tsv)
az ad sp create-for-rbac --name sp-fcg-github-actions --role Contributor --scopes "$RG_ID" --sdk-auth > azure-sp.json
# ⚠ o JSON gerado vai para o GitHub Secret AZURE_CREDENTIALS (ver README) —
# nunca commitar esse arquivo. Apague-o do disco depois de cadastrar o secret.
```

A partir daqui, siga o README deste repositório (seção **"Segredos e deploy da
infra no AKS"**) para: cadastrar os GitHub Secrets, aplicar a infra
compartilhada (`deploy-infra.yml`) e os 4 microsserviços.

## Problemas reais encontrados e já corrigidos no código

Estes três já estão resolvidos nos manifestos deste repositório — registrados
aqui só para quem for recriar o ambiente entender o porquê das configurações:

1. **Postgres não inicializava** (`initdb: directory exists but is not empty`)
   — discos de bloco da Azure já vêm com um `lost+found`. Corrigido com
   `PGDATA=/var/lib/postgresql/data/pgdata` em `k8s/infra/postgres-deployment.yaml`.
2. **Elasticsearch em `CrashLoopBackOff`** (`AccessDeniedException` no node
   lock) — o disco da Azure monta com dono `root`, mas o processo roda como
   uid 1000. Corrigido com `securityContext.fsGroup: 1000` em
   `k8s/infra/elasticsearch-deployment.yaml`.
3. **RabbitMQ em `CrashLoopBackOff`** nos nós `Standard_B2s` — o comando
   `rabbitmq-diagnostics` ultrapassava o timeout padrão de 1s do Kubernetes
   em VMs burstable. Corrigido com `timeoutSeconds: 5` nas probes em
   `k8s/infra/rabbitmq-deployment.yaml`.

## Recursos que a própria Azure cria sozinha (não provisionamos)

Ao usar a subscription, a Azure cria automaticamente, fora do nosso resource
group, o `NetworkWatcherRG` (diagnóstico de rede) e um
`MA_defaultazuremonitorworkspace-...` (workspace padrão de monitoramento).
Nenhum dos dois tem custo relevante parado (só cobram se recursos
ativos — flow logs, ingestão de métricas — forem configurados neles, o que
não fizemos). Não precisam ser apagados.

## Controle de custo

- **Pausa entre sessões de trabalho** (preserva tudo, retoma em minutos): ver
  seção "Controle de custo: parar/retomar o cluster entre sessões" no
  `README.md` deste repositório.
- **Encerramento definitivo** (apaga tudo, sem volta):

```bash
# 1. Apaga o AKS — isso já apaga em cascata o resource group gerenciado
#    (MC_rg-fcg-techchallenge_aks-fcg-techchallenge_eastus) com nós, discos,
#    Load Balancer e IPs públicos.
az aks delete --resource-group rg-fcg-techchallenge --name aks-fcg-techchallenge --yes --no-wait

# 2. Aguarde terminar (acompanhe com o comando abaixo até não retornar nada),
#    depois apague o que sobrou (o Container Registry e suas imagens):
az aks list --resource-group rg-fcg-techchallenge -o table   # repita até vir vazio
az group delete --name rg-fcg-techchallenge --yes --no-wait
```

Opcional (não gera custo, é só limpeza de identidade): remover o Service
Principal com `az ad sp delete --id <appId>` depois que o GitHub não precisar
mais dele.
