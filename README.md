# payment-ecosystem

Repositório **guarda-chuva** do ecossistema de pagamentos PIX do projeto final de
Arquitetura de Software e Ágil II. Ele não contém código de serviço próprio — **orquestra**
os microsserviços do grupo (via git submodules) e entrega o que amarra tudo: um
`docker-compose` que sobe o ecossistema completo, os contratos compartilhados (PACT) e a
documentação de arquitetura e de replicação em Cloud.

## Arquitetura

```
                 POST /api/v1/pagamentos
   Cliente ─────────────────────────────►  payment-core (SAGA)         :8080
                                                │
                                                │  POST /comprovantes        (202 + id)
                                                │  GET  /comprovantes/{id}    (confirma)
                                                ▼
                                           comprovantes                 :8081
                                          ┌───────────────┐
                                RabbitMQ  │ POST → fila →  │  persiste
                                   Redis  │ GET (cache-aside, 3 tentativas → 404)
                                   Kafka  │ publica "Pagamento Realizado" ─┐
                                          └───────────────┘                │
                                                                           ▼
                                                              Notificação (@RetryableTopic)
                                                              (consumer embutido no comprovantes)
```

- **payment-core** — Membro 1. Recebe o pagamento, orquestra a SAGA e só dá a fatura como
  paga se o comprovante for confirmado. Resiliência com Resilience4j.
- **comprovantes** — Membros 2/3/4. POST assíncrono via RabbitMQ, GET com cache-aside no
  Redis, evento de notificação no Kafka e consumer de notificação com `@RetryableTopic`.

Detalhes em [`docs/arquitetura.md`](docs/arquitetura.md).

## Serviços e submodules

| Submodule (`services/`) | Repositório | Branch | Papel |
|---|---|---|---|
| `payment-core` | [meli-mais/payment-core](https://github.com/meli-mais/payment-core) | `develop` | Core & SAGA (Membro 1) |
| `comprovantes` | [meli-mais/vigilant-goggles](https://github.com/meli-mais/vigilant-goggles) | `main` | Comprovantes + Notificação (Membros 2/3/4) |

> O código do comprovantes fica em `services/comprovantes/ms-comprovantes` (o projeto está
> aninhado dentro do repo).

## Como rodar tudo

Pré-requisitos: **Docker** + **Docker Compose**.

```bash
# 1. Clonar já com os submodules
git clone --recurse-submodules https://github.com/meli-mais/payment-ecosystem.git
cd payment-ecosystem

# (se clonou sem --recurse-submodules)
git submodule update --init --recursive

# 2. Subir o ecossistema completo
docker compose up --build
```

### Portas

| Serviço | URL |
|---|---|
| payment-core (SAGA) | http://localhost:8080 — Swagger em `/swagger-ui.html` |
| comprovantes | http://localhost:8081 — H2 em `/h2-console` |
| RabbitMQ (management) | http://localhost:15672 — guest/guest |
| Kafka UI | http://localhost:8090 |
| Redis | localhost:6379 |
| Kafka | localhost:9092 |

### Teste de fumaça (happy path)

```bash
curl -i -X POST http://localhost:8080/api/v1/pagamentos \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{
    "nome": "Giovanni Vicente",
    "tipo_documento": "CPF",
    "numero_documento": "50329291076",
    "numero_agencia": "2022",
    "numero_conta": "00276",
    "digito_verificador_conta": "0",
    "valor_transacao": 23.99,
    "tipo_chave_pix_destino": "CELULAR",
    "chave_pix_destino": "11948755536",
    "nome_cliente_destino": "Fernando Augusto",
    "identificacao_pix": "Churrasco de domingo",
    "data_hora_transacao": "2026-07-10T20:03:57.116061100"
  }'
```

Acompanhe o comprovante sendo persistido (RabbitMQ) e a notificação publicada (Kafka UI).

## Contratos compartilhados (PACT)

O contrato consumidor→provedor entre `payment-core` e `comprovantes` fica em
[`contracts/`](contracts/README.md). É o que garante que os dois serviços continuam
compatíveis mesmo evoluindo em repositórios separados.

## Atualizar os submodules para a última versão dos serviços

```bash
git submodule update --remote --merge
git add services/ && git commit -m "chore: atualiza submodules"
```

## Documentação

- [`docs/arquitetura.md`](docs/arquitetura.md) — visão de arquitetura e fluxo SAGA.
- [`docs/replicacao-cloud.md`](docs/replicacao-cloud.md) — estratégia de replicação em Cloud
  (item 5 da rubrica).
