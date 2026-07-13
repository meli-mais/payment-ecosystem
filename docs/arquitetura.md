# Arquitetura do Ecossistema de Pagamentos PIX

## Visão geral

Sistema distribuído que processa pagamentos de faturas via PIX, emite comprovantes e
notifica o cliente. Aplica DDD, comunicação assíncrona, cache, resiliência e testes de
contrato. Bancos de dados segregados por serviço.

```
                 POST /api/v1/pagamentos
   Cliente ─────────────────────────────►  payment-core (Orquestrador SAGA)     :8080
                                                │        H2 (faturas) — segregado
                                                │
                                                │  (1) POST /comprovantes  → 202 Accepted + id
                                                │  (2) GET  /comprovantes/{id} em polling
                                                │      até 200 (confirmado) ou esgotar tentativas
                                                ▼
                                           comprovantes                          :8081
                                          ┌──────────────────────────────┐
                            RabbitMQ ────►│ POST: valida → publica na fila │
                                          │       consumer grava no H2     │  H2 (comprovantes)
                               Redis ────►│ GET: cache-aside, 3 tentativas │
                                          │      antes de 404              │
                               Kafka ────►│ ao gravar, publica evento      │
                                          │ "Pagamento Realizado" ─────────┼──┐
                                          └──────────────────────────────┘   │
                                                                              ▼
                                                         Notificação (subscriber Kafka)
                                                         @RetryableTopic (4 tentativas, DLT)
```

## Serviços

### payment-core — Core & SAGA (Membro 1)
- **Stack:** Spring Boot (Java 21), WebFlux WebClient, Resilience4j, H2, arquitetura
  hexagonal (Ports & Adapters).
- **Responsabilidade:** recebe o pagamento, orquestra a SAGA e garante que a fatura só é
  dada como paga se o comprovante for **confirmado**. Idempotência via `Idempotency-Key`.
- **Resiliência:** Circuit Breaker + Retry na chamada ao comprovantes; polling de
  confirmação com backoff.
- **Repo:** `meli-mais/payment-core` (submodule `services/payment-core`).

### comprovantes — Comprovantes + Notificação (Membros 2/3/4)
- **Stack:** Spring Boot (Java 17), RabbitMQ, Redis, Spring Kafka, H2.
- **POST /comprovantes:** valida, gera UUID v4, publica na fila RabbitMQ e retorna 202; um
  consumer grava no banco de forma assíncrona.
- **GET /comprovantes/{id}:** cache-aside no Redis; em cache miss busca no banco com até 3
  tentativas antes de 404.
- **Notificação:** ao persistir, publica evento no tópico Kafka; um consumer com
  `@RetryableTopic` reprocessa em caso de falha (backoff exponencial + DLT).
- **Repo:** `meli-mais/vigilant-goggles` (submodule `services/comprovantes`, projeto em
  `ms-comprovantes/`).

## Contrato de integração Core ↔ Comprovantes

Validado campo a campo (ver `contracts/`):

| Item | Valor |
|---|---|
| POST | `POST {base}/comprovantes` → `202` com `{ identificador_comprovante, data_hora_requisicao }` |
| GET | `GET {base}/comprovantes/{id}` → `200` (confirmado) ou `404` (ainda não persistido) |
| Payload | 12 campos snake_case (ver contrato) |
| `tipo_documento` | `CPF` \| `CNPJ` |
| `tipo_chave_pix_destino` | `CELULAR` \| `EMAIL` \| `CPF` \| `CNPJ` \| `CHAVE_ALEATORIA` |
| Datas | ISO-8601 `LocalDateTime` (sem timezone) |
| `base` (Docker) | `http://comprovantes:8080` (via `COMPROVANTES_BASE_URL`) |

## Padrão SAGA (orquestração)

1. `payment-core` cria a fatura em estado **pendente** (idempotente pela `Idempotency-Key`).
2. Chama `POST /comprovantes` — recebe 202 + `identificador_comprovante`.
3. Faz **polling** em `GET /comprovantes/{id}` até confirmar a persistência.
4. **Sucesso:** marca a fatura como **paga**. **Falha/timeout:** compensa marcando a
   fatura como **falha** (a SAGA garante que não existe fatura paga sem comprovante).

## Decisões que valem registrar

- **Notificação não é um deploy separado:** o consumer de notificação vive dentro do
  `comprovantes`. O `payment-core` nunca fala com notificação — nem direto nem indireto.
- **Bancos segregados:** cada serviço tem seu próprio H2 (troca por Postgres/MySQL é só
  configuração para um ambiente real).
