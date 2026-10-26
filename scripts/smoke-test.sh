#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Uso: smoke-test.sh [BASE_URL]

Pruebas de humo post-despliegue contra el gateway del Order Manager.

Argumentos:
  BASE_URL            URL del gateway (por defecto $SMOKE_BASE_URL o http://localhost:8098)

Variables de entorno:
  EXPECTED_REPLICAS   Replicas distintas que deben responder tras el gateway (por defecto 1)
  EXPECTED_COMMIT     Commit esperado en /actuator/info (por defecto $GIT_COMMIT; vacio omite la prueba)
  LB_SAMPLES          Peticiones usadas para verificar el balanceo (por defecto 20)
  CURL_TIMEOUT        Timeout por peticion en segundos (por defecto 10)
  READY_RETRIES       Reintentos de readiness antes de fallar (por defecto 10)
  READY_INTERVAL      Segundos entre reintentos de readiness (por defecto 3)
  GITHUB_STEP_SUMMARY Si existe, se agrega una tabla con los resultados

Codigos de salida: 0 todas aprobadas, 1 alguna fallida, 2 error de uso o dependencias.
EOF
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

require_uint() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name debe ser un entero no negativo (valor: '$value')"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
(( $# <= 1 )) || { usage >&2; exit 2; }

BASE_URL="${1:-${SMOKE_BASE_URL:-http://localhost:8098}}"
BASE_URL="${BASE_URL%/}"
readonly BASE_URL
readonly EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-1}"
readonly EXPECTED_COMMIT="${EXPECTED_COMMIT:-${GIT_COMMIT:-}}"
readonly LB_SAMPLES="${LB_SAMPLES:-20}"
readonly CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
readonly READY_RETRIES="${READY_RETRIES:-10}"
readonly READY_INTERVAL="${READY_INTERVAL:-3}"

[[ "$BASE_URL" =~ ^https?://[^[:space:]]+$ ]] || die "BASE_URL invalida: '$BASE_URL'"
require_uint EXPECTED_REPLICAS "$EXPECTED_REPLICAS"
require_uint LB_SAMPLES "$LB_SAMPLES"
require_uint CURL_TIMEOUT "$CURL_TIMEOUT"
require_uint READY_RETRIES "$READY_RETRIES"
require_uint READY_INTERVAL "$READY_INTERVAL"
(( LB_SAMPLES >= EXPECTED_REPLICAS )) || die "LB_SAMPLES ($LB_SAMPLES) debe ser >= EXPECTED_REPLICAS ($EXPECTED_REPLICAS)"
(( CURL_TIMEOUT > 0 )) || die "CURL_TIMEOUT debe ser mayor que 0"

for dependency in curl jq; do
  command -v "$dependency" >/dev/null 2>&1 || die "dependencia requerida no encontrada: $dependency"
done

WORK_DIR="$(mktemp -d)" || die "no se pudo crear un directorio temporal"
readonly WORK_DIR
readonly BODY_FILE="$WORK_DIR/body"
readonly HEADERS_FILE="$WORK_DIR/headers"
readonly ERROR_FILE="$WORK_DIR/error"
readonly CUSTOMER_NAME="Smoke Test ${GITHUB_RUN_ID:-local}-$$"

PASSED=0
FAILED=0
RESULTS=""
HTTP_CODE=""
TRANSPORT_ERROR=""
ORDER_ID=""

cleanup() {
  local status=$? code
  if [[ -n "$ORDER_ID" ]]; then
    printf 'Limpieza: eliminando pedido de prueba %s\n' "$ORDER_ID" >&2
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
      -X DELETE "$BASE_URL/api/orders/$ORDER_ID")" || code="000"
    if [[ "$code" != "204" && "$code" != "404" ]]; then
      printf 'ADVERTENCIA: no se pudo eliminar el pedido de prueba %s (HTTP %s)\n' "$ORDER_ID" "$code" >&2
    fi
  fi
  rm -rf -- "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT

request() {
  local method="$1" path="$2" payload="${3:-}"
  local -a args=(
    -sS
    -X "$method"
    --max-time "$CURL_TIMEOUT"
    -o "$BODY_FILE"
    -D "$HEADERS_FILE"
    -w '%{http_code}'
    -H 'Accept: application/json'
  )
  if [[ -n "$payload" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$payload")
  fi
  : >"$BODY_FILE"
  : >"$HEADERS_FILE"
  if HTTP_CODE="$(curl "${args[@]}" "$BASE_URL$path" 2>"$ERROR_FILE")"; then
    TRANSPORT_ERROR=""
  else
    HTTP_CODE="000"
    TRANSPORT_ERROR="$(tr '\n' ' ' <"$ERROR_FILE")"
  fi
}

header_value() {
  local name="$1"
  grep -i "^${name}:" "$HEADERS_FILE" | tail -n 1 | cut -d: -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

sanitize() {
  local text
  text="$(printf '%s' "$1" | tr '\r\n' '  ')"
  text="${text//|/\\|}"
  printf '%.200s' "$text"
}

record() {
  local outcome="$1" description="$2" detail
  detail="$(sanitize "$3")"
  if [[ "$outcome" == "PASS" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  RESULTS+="| ${outcome} | ${description} | ${detail} |"$'\n'
  printf '[%s] %s (%s)\n' "$outcome" "$description" "$detail"
}

failure_detail() {
  local expected="$1"
  if [[ -n "$TRANSPORT_ERROR" ]]; then
    printf 'sin respuesta, esperado HTTP %s: %s' "$expected" "$TRANSPORT_ERROR"
  else
    printf 'HTTP %s, esperado %s: %s' "$HTTP_CODE" "$expected" "$(head -c 200 "$BODY_FILE")"
  fi
}

expect() {
  local description="$1" expected="$2" filter="${3:-}"
  shift $(( $# < 3 ? $# : 3 ))
  if [[ "$HTTP_CODE" != "$expected" ]]; then
    record FAIL "$description" "$(failure_detail "$expected")"
    return 1
  fi
  if [[ -n "$filter" ]] && ! jq -e "$@" "$filter" "$BODY_FILE" >/dev/null 2>"$ERROR_FILE"; then
    record FAIL "$description" "HTTP $HTTP_CODE, cuerpo no cumple '$filter': $(head -c 200 "$BODY_FILE") $(tr '\n' ' ' <"$ERROR_FILE")"
    return 1
  fi
  record PASS "$description" "HTTP $HTTP_CODE"
}

wait_for_readiness() {
  local attempt
  for (( attempt = 1; attempt <= READY_RETRIES + 1; attempt++ )); do
    request GET /actuator/health/readiness
    if [[ "$HTTP_CODE" == "200" ]] && jq -e '.status == "UP"' "$BODY_FILE" >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt <= READY_RETRIES )); then
      printf 'Readiness no disponible (HTTP %s), reintento %d/%d en %ss\n' "$HTTP_CODE" "$attempt" "$READY_RETRIES" "$READY_INTERVAL" >&2
      sleep "$READY_INTERVAL"
    fi
  done
  return 1
}

test_health() {
  wait_for_readiness || true
  expect "Readiness via gateway (app + BD)" 200 '.status == "UP"' || true

  request GET /actuator/health/liveness
  expect "Liveness via gateway" 200 '.status == "UP"' || true

  request GET /actuator/info
  if [[ -n "$EXPECTED_COMMIT" ]]; then
    expect "Trazabilidad: /actuator/info expone el commit desplegado" 200 '.app.commit == $commit' --arg commit "$EXPECTED_COMMIT" || true
  else
    expect "Endpoint /actuator/info disponible" 200 'type == "object"' || true
  fi
}

test_gateway() {
  local request_id
  request GET /actuator/health
  request_id="$(header_value X-Request-Id)"
  if [[ "$HTTP_CODE" == "200" && -n "$request_id" ]]; then
    record PASS "Gateway propaga X-Request-Id" "X-Request-Id: $request_id"
  else
    record FAIL "Gateway propaga X-Request-Id" "HTTP $HTTP_CODE, cabecera ausente ${TRANSPORT_ERROR}"
  fi

  request GET /actuator/env
  expect "Actuator sensible bloqueado en gateway (/actuator/env)" 404 || true

  request GET /actuator/heapdump
  expect "Actuator sensible bloqueado en gateway (/actuator/heapdump)" 404 || true
}

test_order_flow() {
  local payload
  payload="$(jq -cn --arg customer "$CUSTOMER_NAME" \
    '{customerName: $customer, items: [{productName: "Teclado", quantity: 2, unitPrice: 19990.00}]}')"

  request POST /api/orders "$payload"
  if [[ "$HTTP_CODE" == "201" ]]; then
    ORDER_ID="$(jq -r 'if (.id | type) == "number" then .id else empty end' "$BODY_FILE" 2>/dev/null || true)"
  fi
  expect "Crear pedido (POST /api/orders)" 201 \
    '(.id | type) == "number" and .status == "PENDING" and .customerName == $customer and .totalAmount == 39980 and (.items | length) == 1' \
    --arg customer "$CUSTOMER_NAME" || true

  if [[ -z "$ORDER_ID" ]]; then
    record FAIL "Flujo de negocio del pedido" "omitido: no se obtuvo el id del pedido creado"
    return
  fi

  request GET "/api/orders/$ORDER_ID"
  expect "Consultar pedido creado (GET /api/orders/{id})" 200 \
    '.id == ($id | tonumber) and .status == "PENDING"' --arg id "$ORDER_ID" || true

  request POST "/api/orders/$ORDER_ID/items" '{"productName":"Mouse","quantity":1,"unitPrice":5000.50}'
  expect "Agregar item a pedido PENDING" 200 \
    '(.items | length) == 2 and .totalAmount == 44980.5' || true

  request PUT "/api/orders/$ORDER_ID/confirm"
  expect "Confirmar pedido (PENDING -> CONFIRMED)" 200 '.status == "CONFIRMED"' || true

  request PUT "/api/orders/$ORDER_ID/confirm"
  expect "Rechazar transicion invalida (CONFIRMED -> CONFIRMED)" 409 '.status == 409' || true

  request POST "/api/orders/$ORDER_ID/items" '{"productName":"Mouse","quantity":1,"unitPrice":5000.50}'
  expect "Rechazar modificacion de pedido CONFIRMED" 409 '.status == 409' || true

  request PUT "/api/orders/$ORDER_ID/cancel"
  expect "Cancelar pedido (CONFIRMED -> CANCELLED)" 200 '.status == "CANCELLED"' || true

  request DELETE "/api/orders/$ORDER_ID"
  if expect "Eliminar pedido de prueba (DELETE /api/orders/{id})" 204; then
    request GET "/api/orders/$ORDER_ID"
    expect "Pedido eliminado ya no existe" 404 '.status == 404' || true
    ORDER_ID=""
  fi
}

test_error_handling() {
  request GET /api/orders/9223372036854775807
  expect "Pedido inexistente devuelve 404" 404 '.status == 404' || true

  request POST /api/orders '{"customerName":""}'
  expect "Validacion de entrada (400)" 400 '.status == 400 and (.fields.customerName | type) == "string"' || true
}

test_load_balancing() {
  local sample upstream errors=0 distinct
  local -A upstreams=()
  for (( sample = 1; sample <= LB_SAMPLES; sample++ )); do
    request GET /api/orders
    if [[ "$HTTP_CODE" != "200" ]]; then
      errors=$((errors + 1))
      continue
    fi
    upstream="$(header_value X-Upstream)"
    upstream="${upstream##*,}"
    upstream="${upstream//[[:space:]]/}"
    [[ -n "$upstream" ]] && upstreams["$upstream"]=1
  done
  distinct="${#upstreams[@]}"
  if (( errors == 0 && distinct >= EXPECTED_REPLICAS )); then
    record PASS "Balanceo entre replicas" "$distinct distintas en $LB_SAMPLES peticiones: ${!upstreams[*]}"
  else
    record FAIL "Balanceo entre replicas" "$distinct distintas (esperado >= $EXPECTED_REPLICAS), $errors peticiones sin HTTP 200"
  fi
}

write_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  if ! {
    printf '### Pruebas de humo post-despliegue\n'
    printf 'Gateway: `%s`\n\n' "$BASE_URL"
    printf '| Estado | Prueba | Detalle |\n'
    printf '|---|---|---|\n'
    printf '%s' "$RESULTS"
    printf '\n**%d aprobadas, %d fallidas**\n' "$PASSED" "$FAILED"
  } >>"$GITHUB_STEP_SUMMARY"; then
    printf 'ADVERTENCIA: no se pudo escribir el resumen en %s\n' "$GITHUB_STEP_SUMMARY" >&2
  fi
}

main() {
  printf 'Pruebas de humo contra %s\n' "$BASE_URL"
  test_health
  test_gateway
  test_order_flow
  test_error_handling
  test_load_balancing
  write_summary
  printf 'Resultado: %d aprobadas, %d fallidas\n' "$PASSED" "$FAILED"
  (( FAILED == 0 )) || exit 1
}

main
