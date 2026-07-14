# Requisitos × Entrega

Mapa de tudo o que o desafio (`Projeto-Final-arq-soft-agil-II`) exige e **onde** cada ponto
foi entregue no ecossistema. Serve como checklist de avaliação.

## Requisitos arquiteturais

| # | Requisito | Status | Onde / evidência |
|---|---|---|---|
| **1** | **MS Pagamento/Fatura (SAGA)** — recebe PIX; fatura paga só se o comprovante for gerado | ✅ | `payment-core` (Java). Orquestração SAGA; e2e T1 mostra fatura `PAGA` só após confirmar o comprovante |
| **2** | **MS Comprovantes** — POST → `202`+UUID v4 → **RabbitMQ** → consumer grava no banco; GET → **Redis** (cache-aside) → 3 tentativas → `404` | ✅ | `ms-comprovantes` (Python). Fila RabbitMQ + cache Redis + Postgres |
| **3** | **MS Notificação** — evento "Pagamento Realizado" no **tópico Kafka**; subscriber; **`@RetryableTopic`** | ✅ | `notificacao` (Java, profile `integration`). e2e T1 confirma o evento recebido |
| **4** | **Testes de Contrato (PACT)** entre Pagamento e Comprovantes | ✅ | `payment-core/ComprovanteContractTest` + `contracts/` (pact compartilhado) |
| **5** | **Cloud Replicado** — documento de estratégia de replicação | ✅ | [`docs/replicacao-cloud.md`](replicacao-cloud.md) |

## Rubricas de avaliação

| Rubrica | Status | Como é atendida |
|---|---|---|
| 1. Arquitetura de Microsserviços (DDD, domínios separados) | ✅ | Os 3 serviços em arquitetura hexagonal; bancos segregados (H2 × Postgres × H2) |
| 2. Sessões e Cache (Redis) | ✅ | Cache-aside no Comprovantes com TTL e 3 tentativas |
| 3. Comunicação Assíncrona (Filas **e** Tópicos) | ✅ | **RabbitMQ** (Comprovantes) **e** **Kafka** (Notificação) — os dois |
| 4. Arquitetura Amigável a Testes (Contract Testing) | ✅ | PACT entre Core e Comprovantes + e2e do ecossistema |
| 5. Cloud Replicado | ✅ | Documento de replicação em Cloud |

## Contrato de payload (pág. 2 do PDF)

✅ Validado campo a campo **e ao vivo** (e2e). Os 12 campos snake_case, a resposta `202`
(`identificador_comprovante` + `data_hora_requisicao`) e os enums batem entre os serviços —
inclusive `CHAVE_ALEATORIA`.

## Diferenciais além do mínimo

- **Ecossistema poliglota** (Java + Python) integrado por contrato (HTTP + evento Kafka).
- **Idempotência** no pagamento (`Idempotency-Key`) — e2e T3.
- **Resiliência** no Core (Resilience4j: Circuit Breaker + Retry) e na Notificação
  (`@RetryableTopic` com backoff + DLT).
- **Orquestração única** (`docker compose up`) sobe os 3 serviços + infra.
- **Teste E2E automatizado** do ecossistema ([`tests/e2e.sh`](../tests/e2e.sh)).
- **Contrato de contrato compartilhado** (PACT) versionado em `contracts/`.

## Divisão por membros (referência do PDF)

| Membro | Responsabilidade | Serviço |
|---|---|---|
| 1 | Core & SAGA | `payment-core` |
| 2 | Mensageria e Persistência (POST + RabbitMQ) | `ms-comprovantes` |
| 3 | Performance e Leitura (GET + Redis) | `ms-comprovantes` |
| 4 | Eventos, Resiliência e Qualidade (Kafka, `@RetryableTopic`, PACT) | `notificacao` |
