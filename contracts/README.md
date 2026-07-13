# Contratos compartilhados (PACT)

Contract testing entre `payment-core` (consumer) e `comprovantes` (provider). Como os dois
serviços vivem em repositórios separados, o contrato precisa ser **compartilhado e
verificado dos dois lados** — senão cada time testa só o próprio pact e a integração real
fica sem rede de segurança.

## Arquivo

- [`pacts/payment-service-comprovantes-service.json`](pacts/payment-service-comprovantes-service.json)
  — gerado pelo `payment-core` (`ComprovanteContractTest`), descreve o que o Core espera do
  Comprovantes: `POST /comprovantes` (202) e `GET /comprovantes/{id}` (200/404).

Regerar (no submodule do core): `./mvnw -Dtest=ComprovanteContractTest test` →
`target/pacts/`.

## ⚠️ Gap conhecido a fechar

Hoje os dois lados verificam pacts **desconectados**:

- O Core gera pact com provider **`comprovantes-service`**.
- O teste provider do Comprovantes (`ComprovanteProviderPactTest`) usa
  `@Provider("ms-comprovantes-api")` e lê o `target/pacts` **dele mesmo**.

Ou seja, o Comprovantes **não verifica** o contrato do Core. Para fechar:

1. Alinhar o **nome do provider** entre os dois (ex.: ambos `comprovantes-service`).
2. O Comprovantes verificar **este** arquivo — via `@PactFolder` apontando para o pact do
   Core, ou via **Pact Broker** compartilhado (recomendado).

## Opção recomendada: Pact Broker

```bash
# subir um broker local para o grupo (exemplo)
docker run -d --name pact-broker -p 9292:9292 pactfoundation/pact-broker
```

- **Consumer (payment-core):** publica o pact no broker após o build.
- **Provider (comprovantes):** verifica contra o broker no CI (`@PactBroker`), com
  *provider states* já existentes ("um payload de comprovante valido", "comprovante existe",
  "comprovante nao existe").

Assim qualquer mudança incompatível de um lado quebra o build do outro — que é o objetivo do
contract testing.
