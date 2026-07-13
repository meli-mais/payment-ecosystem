# Estratégia de Replicação em Cloud

> Documento da rubrica (item 5 — "Cloud Replicado"): como este ecossistema seria replicado e
> escalado em nuvem para alta disponibilidade. Não há base legada para migrar; o foco é a
> estratégia de replicação da aplicação construída. Este é um ponto de partida — refine com a
> cloud escolhida pelo grupo (AWS/GCP/Azure).

## 1. Princípio: separar o que é *stateless* do que é *stateful*

| Componente | Estado? | Estratégia de replicação |
|---|---|---|
| `payment-core` | Stateless* | Réplicas horizontais atrás de load balancer + autoscaling |
| `comprovantes` | Stateless* | Réplicas horizontais + autoscaling |
| Banco (H2 → gerenciado) | Stateful | Serviço gerenciado com réplicas multi-AZ |
| Redis | Stateful | Cluster/replicação gerenciada |
| RabbitMQ | Stateful | Cluster com filas espelhadas/quorum |
| Kafka | Stateful | Cluster multi-broker, partições replicadas |

\* Os serviços são stateless na aplicação (todo estado vive em banco/cache/broker), então
escalam horizontalmente sem afinidade de sessão. Pré-requisito: **idempotência** (o
`payment-core` já usa `Idempotency-Key`) para tolerar reprocessamento e retries entre
réplicas.

## 2. Serviços de aplicação (payment-core, comprovantes)

- **Empacotamento:** imagens Docker (já existem) publicadas num registry gerenciado
  (ECR / Artifact Registry / ACR).
- **Orquestração:** Kubernetes gerenciado (EKS / GKE / AKS) ou runtime serverless de
  containers (ECS Fargate / Cloud Run).
- **Réplicas:** mínimo 2 por serviço, distribuídas em **múltiplas zonas de disponibilidade**
  (AZs) para tolerar a queda de uma zona.
- **Autoscaling:** HPA por CPU/latência/profundidade de fila. O `comprovantes` deve escalar
  também pela profundidade da fila RabbitMQ (consumers), não só por CPU.
- **Health checks:** liveness/readiness — só recebe tráfego quando as dependências
  (banco/cache/broker) estão acessíveis.
- **Rollout:** rolling update / blue-green para deploy sem downtime.

## 3. Bancos de dados (segregados por serviço)

- Trocar o H2 em memória por banco gerenciado (RDS / Cloud SQL / Azure DB).
- **Alta disponibilidade:** instância primária + **standby síncrono em outra AZ** com
  failover automático.
- **Réplicas de leitura** para consultas (ex.: o GET de comprovantes), aliviando o primário.
- Backups automáticos + point-in-time recovery.

## 4. Cache (Redis)

- Serviço gerenciado (ElastiCache / Memorystore / Azure Cache) em modo réplica/cluster
  multi-AZ com failover.
- O cache é **cache-aside**: sua perda não causa perda de dado (só cache miss → vai ao
  banco), o que simplifica a estratégia de replicação.

## 5. Mensageria

### RabbitMQ (comprovantes)
- Cluster com **quorum queues** (ou filas espelhadas) para não perder mensagem na queda de
  um nó. Serviço gerenciado (Amazon MQ) ou operator no Kubernetes.

### Kafka (notificação)
- Cluster **multi-broker**; tópicos com **replication factor ≥ 3** e `min.insync.replicas`
  adequado, brokers espalhados por AZs.
- Managed: MSK / Confluent Cloud. Consumers em grupo escalam pelo número de partições.
- A resiliência de reprocessamento já está no app (`@RetryableTopic` + DLT).

## 6. Rede, entrada e observabilidade

- **API Gateway / Ingress** único como ponto de entrada, com TLS e rate limiting.
- **Load balancer** distribuindo entre réplicas e AZs.
- **Observabilidade:** métricas (Prometheus/CloudWatch), logs centralizados e tracing
  distribuído para acompanhar a SAGA ponta a ponta entre os serviços.

## 7. Multi-região (evolução)

Para tolerar a queda de uma região inteira: réplicas ativas em ≥ 2 regiões, replicação
assíncrona de banco entre regiões, DNS com failover (health-based routing) e MirrorMaker
para o Kafka. Trade-off: custo e complexidade de consistência — dimensionar conforme o SLA
alvo.

## 8. Resumo

O desenho já favorece a replicação: serviços stateless + idempotentes, estado isolado em
componentes gerenciáveis, comunicação assíncrona e resiliência embutida. Replicar em Cloud é,
essencialmente, **rodar N réplicas de cada serviço em múltiplas AZs** e **usar as versões
gerenciadas e replicadas** de banco, cache e brokers.
