# payment-ecosystem

Repositório **guarda-chuva** do ecossistema de pagamentos PIX do projeto final de
Arquitetura de Software e Ágil II. Ele não contém código de serviço próprio — **orquestra**
os microsserviços do grupo (via git submodules) e entrega o que amarra tudo: um
`docker-compose` que sobe o ecossistema completo, os contratos compartilhados (PACT) e a
documentação de arquitetura e de replicação em Cloud.

## Arquitetura

```
                 POST /api/v1/pagamentos
   Cliente ─────────────────────────────►  payment-core (SAGA, Java)    :8080
                                                │
                                                │  POST /comprovantes        (202 + id)
                                                │  GET  /comprovantes/{id}    (confirma)
                                                ▼
                                     ms-comprovantes (Python/FastAPI)    :8081
                                          ┌───────────────┐
                                RabbitMQ  │ POST → fila →  │  persiste no Postgres
                                   Redis  │ GET (cache-aside, 3 tentativas → 404)
                                Postgres  │                │
                                          └───────┬───────┘
                                                  │  Kafka: evento "Pagamento Realizado"
                                                  ▼
                                       notificacao (Java, @RetryableTopic)   :8082
                                       consome o tópico e "notifica" o cliente
```

- **payment-core** (Java/Spring) — Membro 1. Recebe o pagamento, orquestra a SAGA e só dá a
  fatura como paga se o comprovante for confirmado. Resiliência com Resilience4j.
- **ms-comprovantes** (Python/FastAPI) — POST assíncrono via RabbitMQ (persiste no Postgres),
  GET com cache-aside no Redis (3 tentativas antes do 404); publica o evento no Kafka.
- **notificacao** (Java/Spring) — subscriber Kafka do evento "Pagamento Realizado", com retry
  via `@RetryableTopic`. É o `vigilant-goggles` rodando no profile `integration` (só o papel
  de Notificação); rodando sozinho, ele é o serviço completo de Comprovantes+Notificação.

> O contrato HTTP (paths, payloads snake_case, enums incl. `CHAVE_ALEATORIA`) e o evento Kafka
> (`NotificacaoEvent`) foram validados campo a campo — ver [`docs/arquitetura.md`](docs/arquitetura.md).

Detalhes em [`docs/arquitetura.md`](docs/arquitetura.md).

## Serviços e submodules

| Submodule (`services/`) | Repositório | Branch | Papel |
|---|---|---|---|
| `payment-core` | [meli-mais/payment-core](https://github.com/meli-mais/payment-core) | `develop` | Core & SAGA (Java) — Membro 1 |
| `comprovantes` | [meli-mais/ms-comprovantes](https://github.com/meli-mais/ms-comprovantes) | `feat/notificacao-kafka` | Comprovantes (Python/FastAPI) + producer Kafka |
| `notificacao` | [meli-mais/vigilant-goggles](https://github.com/meli-mais/vigilant-goggles) | `feat/notificacao-integracao` | Notificação (Java, `@RetryableTopic`) |

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
| ms-comprovantes | http://localhost:8081 — Docs em `/docs` |
| notificacao (Java) | http://localhost:8082 |
| RabbitMQ (management) | http://localhost:15672 — guest/guest |
| PostgreSQL | localhost:5432 |
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

A resposta é `202` com a fatura `PAGA`; nos logs do serviço `notificacao` aparece a
"Notificação recebida" (o evento que percorreu o Kafka).

## Testes

Teste **end-to-end** do ecossistema (os 3 serviços juntos, rodando):

```bash
docker compose up -d --build
./tests/e2e.sh
```

Cobre: happy path (SAGA → fatura PAGA + evento Kafka na Notificação), `CHAVE_ALEATORIA`,
idempotência e validação (`400`). Detalhes em [`tests/README.md`](tests/README.md). Os testes
de unidade/arquitetura/contrato ficam **dentro de cada serviço**.

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

- [`docs/arquitetura.md`](docs/arquitetura.md) — visão de arquitetura, fluxo SAGA e contratos.
- [`docs/requisitos-e-entrega.md`](docs/requisitos-e-entrega.md) — mapa requisitos × entrega
  (checklist da rubrica com evidências).
- [`docs/replicacao-cloud.md`](docs/replicacao-cloud.md) — estratégia de replicação em Cloud
  (item 5 da rubrica).
- [`tests/README.md`](tests/README.md) — testes end-to-end do ecossistema.
- [`contracts/README.md`](contracts/README.md) — contrato PACT compartilhado.
