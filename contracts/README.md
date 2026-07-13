# Contratos compartilhados (PACT)

Contract testing entre `payment-core` (consumer, Java) e `ms-comprovantes` (provider,
Python). Como os serviços vivem em repositórios e linguagens diferentes, o contrato precisa
ser **compartilhado e verificado dos dois lados** — senão a integração real fica sem rede de
segurança.

## Arquivo

- [`pacts/payment-service-ms-comprovantes-api.json`](pacts/payment-service-ms-comprovantes-api.json)
  — gerado pelo `payment-core` (`ComprovanteContractTest`). Descreve o que o Core espera do
  Comprovantes: `POST /comprovantes` (202) e `GET /comprovantes/{id}` (200/404). Provider name
  `ms-comprovantes-api`; provider states `um payload de comprovante valido`, `comprovante
  existe`, `comprovante nao existe`. A resposta 202 usa matchers (uuid + datetime), então casa
  com o identificador/timestamp gerados em runtime pelo provider.

Regerar (no submodule do core): `./mvnw -Dtest=ComprovanteContractTest test` → `target/pacts/`.

## Verificação do lado provider (Python)

O `ms-comprovantes` deve verificar este pact com **pact-python** (`Verifier`), servindo os
provider states acima (mockando a camada de persistência). Fluxo recomendado:

- **Consumer (payment-core):** publica o pact (arquivo aqui, ou num Pact Broker).
- **Provider (ms-comprovantes):** roda o `Verifier` contra o pact no CI.

Assim, qualquer mudança incompatível de um lado quebra o build do outro — o objetivo do
contract testing. Enquanto a verificação automatizada do lado Python não existir, este arquivo
serve como o **contrato acordado** de referência para a integração.
