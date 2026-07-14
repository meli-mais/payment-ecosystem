# Testes do ecossistema (End-to-End)

Este diretório tem o **teste de integração ponta a ponta** do ecossistema — o que valida os
**3 microsserviços juntos**, rodando de verdade em containers. Os testes de unidade, de
arquitetura e de contrato (PACT) ficam **dentro de cada serviço** (é lá que eles pertencem);
aqui validamos a integração do todo.

## Como rodar

```bash
# na raiz do payment-ecosystem
docker compose up -d --build     # sobe os 7 containers
./tests/e2e.sh                   # roda o e2e (sai != 0 se algo falhar)
```

O script espera os serviços ficarem prontos, executa os casos e imprime um resumo
`PASSOU/FALHOU`. Pronto para CI (código de saída reflete o resultado).

## O que o `e2e.sh` cobre

| Caso | O que valida | Rubrica / item |
|---|---|---|
| **T1 — happy path** | `POST /pagamentos` → `202` + fatura **PAGA**; e a **Notificação (Java) recebe o evento via Kafka** | SAGA + fila + **tópico** |
| **T2 — CHAVE_ALEATORIA** | o enum bate nos 3 serviços (poliglota) — sem 400 | Contrato / DDD |
| **T3 — idempotência** | mesma `Idempotency-Key` devolve a **mesma** fatura | SAGA (consistência) |
| **T4 — validação** | `tipo_chave_pix_destino` inválido → `400` | Contrato de entrada |
| **T5 — compensação** | para o Comprovantes → `POST` → fatura **FALHOU** (a SAGA compensa); religa no fim | SAGA (caminho de falha) |

Assim a SAGA é provada nos **dois sentidos**: **PAGA** (sucesso) e **FALHOU** (falha/compensação).
O T5 roda por último porque para/religa o container do Comprovantes.

O T1 prova a cadeia inteira: **payment-core → comprovantes (Python) → Kafka → notificacao
(Java)** — contando as linhas "Notificação recebida" no log do container antes/depois do
pagamento.

## Variáveis (opcionais)

| Var | Default |
|---|---|
| `CORE_URL` | `http://localhost:8080` |
| `COMPROVANTES_URL` | `http://localhost:8081` |
| `NOTIFICACAO_CONTAINER` | `pix-notificacao` |

## Testes por serviço (dentro de cada repo)

- **payment-core:** `./mvnw test` — unidade, arquitetura (ArchUnit), contrato (PACT consumer),
  integração WireMock.
- **ms-comprovantes:** `pytest` — unidade + contrato (PACT de mensageria).
- **notificacao (vigilant-goggles):** `./mvnw test` — unidade, retry, PACT (Rabbit/Kafka).
