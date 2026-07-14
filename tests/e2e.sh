#!/usr/bin/env bash
# =============================================================================
# Teste End-to-End do ecossistema PIX (payment-core + comprovantes + notificacao).
#
# Valida o fluxo completo dos 3 microsserviços contra o stack rodando:
#   payment-core (SAGA) --HTTP--> comprovantes (Python) --Kafka--> notificacao (Java)
#
# Uso:
#   docker compose up -d --build      # sobe o ecossistema
#   ./tests/e2e.sh                    # roda os testes
#
# Sai com código 0 se todos passarem, !=0 se algum falhar (pronto para CI).
# =============================================================================
set -uo pipefail

CORE_URL="${CORE_URL:-http://localhost:8080}"
COMPROVANTES_URL="${COMPROVANTES_URL:-http://localhost:8081}"
NOTIFICACAO_CONTAINER="${NOTIFICACAO_CONTAINER:-pix-notificacao}"

PASS=0; FAIL=0
green(){ printf '\033[32m%s\033[0m\n' "$1"; }
red(){   printf '\033[31m%s\033[0m\n' "$1"; }
ok(){   green "  ✅ PASS: $1"; PASS=$((PASS+1)); }
ko(){   red   "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || python -c "import uuid;print(uuid.uuid4())"; }

# Payload PIX base; $1 sobrescreve o tipo de chave (default CELULAR).
payload(){
  local tipo="${1:-CELULAR}" chave="${2:-11948755536}"
  cat <<JSON
{"nome":"Giovanni Vicente","tipo_documento":"CPF","numero_documento":"50329291076",
 "numero_agencia":"2022","numero_conta":"00276","digito_verificador_conta":"0",
 "valor_transacao":23.99,"tipo_chave_pix_destino":"$tipo","chave_pix_destino":"$chave",
 "nome_cliente_destino":"Fernando Augusto","identificacao_pix":"e2e",
 "data_hora_transacao":"2026-07-10T20:03:57.116061100"}
JSON
}

pagar(){ # $1=idempotency-key $2=payload -> imprime "HTTP|body"
  curl -s -w "|%{http_code}" -X POST "$CORE_URL/api/v1/pagamentos" \
    -H "Content-Type: application/json" -H "Idempotency-Key: $1" -d "$2" 2>/dev/null
}

# ----------------------------------------------------------------------------
echo "== Aguardando os serviços ficarem prontos =="
ready=0
for i in $(seq 1 40); do
  c=$(curl -s -o /dev/null -w "%{http_code}" "$CORE_URL/swagger-ui/index.html" 2>/dev/null)
  d=$(curl -s -o /dev/null -w "%{http_code}" "$COMPROVANTES_URL/docs" 2>/dev/null)
  if [ "$c" = "200" ] && [ "$d" = "200" ]; then ready=1; green "  serviços prontos (tentativa $i)"; break; fi
  sleep 3
done
[ "$ready" = "1" ] || { red "Serviços não ficaram prontos. Rodou 'docker compose up -d'?"; exit 2; }

# ----------------------------------------------------------------------------
echo ""; echo "== T1: happy path (CELULAR) → fatura PAGA + Notificação recebe evento Kafka =="
notif_antes=$(docker logs "$NOTIFICACAO_CONTAINER" 2>&1 | grep -c "Notificação recebida")
resp=$(pagar "$(uuid)" "$(payload CELULAR)"); code="${resp##*|}"; body="${resp%|*}"
[ "$code" = "202" ] && ok "POST /pagamentos → 202" || ko "esperava 202, veio $code"
echo "$body" | grep -q '"status":"PAGA"' && ok "fatura status=PAGA" || ko "fatura não ficou PAGA: $body"

echo "  aguardando propagação do evento no Kafka..."
notif_ok=0
for i in $(seq 1 10); do
  notif_depois=$(docker logs "$NOTIFICACAO_CONTAINER" 2>&1 | grep -c "Notificação recebida")
  if [ "$notif_depois" -gt "$notif_antes" ]; then notif_ok=1; break; fi
  sleep 2
done
[ "$notif_ok" = "1" ] && ok "Notificação (Java) recebeu o evento via Kafka (@RetryableTopic)" \
                      || ko "Notificação não recebeu o evento (antes=$notif_antes)"

# ----------------------------------------------------------------------------
echo ""; echo "== T2: CHAVE_ALEATORIA → enum poliglota bate nos 3 serviços =="
resp=$(pagar "$(uuid)" "$(payload CHAVE_ALEATORIA a1b2c3d4-e5f6-7890-abcd-ef1234567890)")
code="${resp##*|}"; body="${resp%|*}"
[ "$code" = "202" ] && echo "$body" | grep -q '"status":"PAGA"' \
  && ok "CHAVE_ALEATORIA → 202 PAGA" || ko "CHAVE_ALEATORIA falhou: $code $body"

# ----------------------------------------------------------------------------
echo ""; echo "== T3: idempotência (mesma Idempotency-Key → mesma fatura) =="
key="$(uuid)"
b1=$(pagar "$key" "$(payload CELULAR)"); b1="${b1%|*}"
b2=$(pagar "$key" "$(payload CELULAR)"); b2="${b2%|*}"
id1=$(echo "$b1" | grep -oE '"faturaId":"[^"]+"'); id2=$(echo "$b2" | grep -oE '"faturaId":"[^"]+"')
[ -n "$id1" ] && [ "$id1" = "$id2" ] && ok "mesma Idempotency-Key devolve a mesma fatura ($id1)" \
  || ko "idempotência falhou: $id1 vs $id2"

# ----------------------------------------------------------------------------
echo ""; echo "== T4: validação (tipo de chave inválido → 400) =="
resp=$(pagar "$(uuid)" "$(payload TIPO_INVALIDO)"); code="${resp##*|}"
[ "$code" = "400" ] && ok "payload inválido → 400 Bad Request" || ko "esperava 400, veio $code"

# ----------------------------------------------------------------------------
# T5 fica por ÚLTIMO: ele para o Comprovantes (indisponibilidade) e religa no fim.
echo ""; echo "== T5: compensação da SAGA (Comprovantes indisponível → fatura FALHOU) =="
COMPROVANTES_CONTAINER="${COMPROVANTES_CONTAINER:-pix-comprovantes}"
docker stop "$COMPROVANTES_CONTAINER" >/dev/null 2>&1 && echo "  comprovantes parado (simulando indisponibilidade)"
sleep 2
resp=$(pagar "$(uuid)" "$(payload CELULAR)"); code="${resp##*|}"; body="${resp%|*}"
if [ "$code" = "202" ] && echo "$body" | grep -q '"status":"FALHOU"'; then
  ok "Comprovantes indisponível → fatura FALHOU (compensação da SAGA)"
else
  ko "esperava 202 + status FALHOU, veio: $code $body"
fi
# religa o Comprovantes e espera ficar pronto (deixa o stack saudável ao fim)
docker start "$COMPROVANTES_CONTAINER" >/dev/null 2>&1
echo "  religando comprovantes..."
for i in $(seq 1 25); do
  d=$(curl -s -o /dev/null -w "%{http_code}" "$COMPROVANTES_URL/docs" 2>/dev/null)
  [ "$d" = "200" ] && { green "  comprovantes de volta (tentativa $i)"; break; }
  sleep 3
done

# ----------------------------------------------------------------------------
echo ""; echo "========================================"
green "PASSOU: $PASS"; [ "$FAIL" -gt 0 ] && red "FALHOU: $FAIL" || echo "FALHOU: 0"
echo "========================================"
[ "$FAIL" -eq 0 ]
