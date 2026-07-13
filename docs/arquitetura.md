# Arquitetura do Ecossistema de Pagamentos PIX

## Visão geral

Sistema distribuído que processa pagamentos de faturas via PIX e emite comprovantes. Aplica
DDD/arquitetura hexagonal nos dois serviços, comunicação assíncrona, cache e resiliência.
Bancos de dados segregados por serviço. Os dois serviços são de **linguagens diferentes** e
conversam por um **contrato HTTP** (REST/JSON) — poliglota, integração por contrato.

```
                 POST /api/v1/pagamentos
   Cliente ─────────────────────────────►  payment-core (SAGA, Java/Spring)     :8080
                                                │        H2 (faturas) — segregado
                                                │
                                                │  (1) POST /comprovantes  → 202 Accepted + id
                                                │  (2) GET  /comprovantes/{id} em polling
                                                │      até 200 (confirmado) ou esgotar tentativas
                                                ▼
                                     ms-comprovantes (Python/FastAPI)            :8081
                                          ┌──────────────────────────────┐
                            RabbitMQ ────►│ POST: valida → publica na fila │
                                          │       consumer grava no banco  │  PostgreSQL
                               Redis ────►│ GET: cache-aside, 3 tentativas │
                                          │      antes de 404              │
                                          └──────────────────────────────┘
```

## Serviços

### payment-core — Core & SAGA (Membro 1)
- **Stack:** Java 21, Spring Boot, WebFlux WebClient, Resilience4j, H2, arquitetura hexagonal
  (Ports & Adapters).
- **Responsabilidade:** recebe o pagamento, orquestra a SAGA e garante que a fatura só é dada
  como paga se o comprovante for **confirmado**. Idempotência via `Idempotency-Key`.
- **Resiliência:** Circuit Breaker + Retry na chamada ao comprovantes; polling de confirmação
  com backoff.
- **Repo:** `meli-mais/payment-core` (submodule `services/payment-core`, branch `develop`).

### ms-comprovantes — Comprovantes (Python)
- **Stack:** Python 3.12, FastAPI/uvicorn, SQLAlchemy async + PostgreSQL, Redis, RabbitMQ
  (aio-pika), Alembic (migrations), Poetry. Arquitetura hexagonal.
- **POST /comprovantes:** valida (Pydantic, `extra="forbid"`), gera UUID v4, publica na fila
  RabbitMQ e retorna 202; um consumer grava no PostgreSQL de forma assíncrona.
- **GET /comprovantes/{id}:** cache-aside no Redis; em cache miss busca no banco com até 3
  tentativas antes de 404.
- **Repo:** `meli-mais/ms-comprovantes` (submodule `services/comprovantes`, branch `develop`).

## Contrato de integração Core ↔ Comprovantes

Validado campo a campo entre o Java (consumer) e o Python (provider):

| Item | Valor |
|---|---|
| POST | `POST {base}/comprovantes` → `202` com `{ identificador_comprovante, data_hora_requisicao }` |
| GET | `GET {base}/comprovantes/{id}` → `200` (confirmado) ou `404` (ainda não persistido) |
| Payload | 12 campos snake_case; o Python usa `extra="forbid"` — o Core envia exatamente esses campos |
| `tipo_documento` | `CPF` \| `CNPJ` |
| `tipo_chave_pix_destino` | `CELULAR` \| `EMAIL` \| `CPF` \| `CNPJ` \| `CHAVE_ALEATORIA` |
| Datas | ISO-8601 (Java envia `LocalDateTime`; Pydantic parseia) |
| `base` (Docker) | `http://comprovantes:8080` (via `COMPROVANTES_BASE_URL`) |

> O enum do Python foi **portado do Java preservando os nomes** (inclusive `CHAVE_ALEATORIA`),
> então os cinco tipos de chave PIX batem exatamente entre os dois serviços.

## Padrão SAGA (orquestração)

1. `payment-core` cria a fatura em estado **pendente** (idempotente pela `Idempotency-Key`).
2. Chama `POST /comprovantes` — recebe 202 + `identificador_comprovante`.
3. Faz **polling** em `GET /comprovantes/{id}` até confirmar a persistência.
4. **Sucesso:** marca a fatura como **paga**. **Falha/timeout:** compensa marcando a fatura
   como **falha** (a SAGA garante que não existe fatura paga sem comprovante).

## Decisões que valem registrar

- **Integração poliglota por contrato:** Core em Java, Comprovantes em Python; o acoplamento é
  só o contrato HTTP. Cada serviço evolui na sua linguagem/stack.
- **Bancos segregados:** Core usa H2; Comprovantes usa PostgreSQL. Independentes.
- **Notificação (Kafka):** não faz parte deste serviço Python nem do Core. Se o grupo entregar
  o serviço de Notificação, ele é um subscriber à parte e não altera a integração Core↔Comprovantes.
- **Contrato de risco — formato de data:** o Java serializa `LocalDateTime` com até
  nanossegundos; o `datetime` do Python (Pydantic) trunca a microssegundos. Não quebra o
  parsing, mas vale conferir no teste de fumaça se a precisão importar.
