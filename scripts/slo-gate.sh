#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: slo-gate.sh BASE_URL PROMETHEUS_URL

Genera trafico controlado contra la nueva revision y evalua sus SLO con las metricas
de Istio en Prometheus. Termina con codigo 1 si la revision no cumple, lo que detiene
el pipeline y activa el rollback.

Variables de entorno:
  REVISION            Revision desplegada (label app.kubernetes.io/version, obligatoria)
  APP_NAMESPACE       Namespace de la aplicacion (por defecto infra/versions.conf)
  LOAD_SECONDS        Duracion de la carga (por defecto 60)
  LOAD_CONCURRENCY    Clientes concurrentes (por defecto 4)
  MIN_REQUESTS        Solicitudes minimas observadas en Prometheus (por defecto 50)
  MAX_ERROR_RATIO     Proporcion maxima de respuestas 5xx (por defecto 0.01)
  MAX_P95_MS          Latencia p95 maxima en milisegundos (por defecto 1000)
  EXPECTED_REPLICAS   Pods distintos de la revision que deben recibir trafico (por defecto 2)
  SCRAPE_WAIT         Segundos de espera para la recoleccion de metricas (por defecto 45)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 2 )) || { usage >&2; exit 2; }

load_versions
require_cmd curl jq awk
require_env REVISION

BASE_URL="${1%/}"
PROM_URL="${2%/}"
LOAD_SECONDS="${LOAD_SECONDS:-60}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-4}"
MIN_REQUESTS="${MIN_REQUESTS:-50}"
MAX_ERROR_RATIO="${MAX_ERROR_RATIO:-0.01}"
MAX_P95_MS="${MAX_P95_MS:-1000}"
SCRAPE_WAIT="${SCRAPE_WAIT:-45}"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-2}"

for name in LOAD_SECONDS LOAD_CONCURRENCY MIN_REQUESTS MAX_P95_MS SCRAPE_WAIT EXPECTED_REPLICAS; do
  [[ "${!name}" =~ ^[0-9]+$ ]] || die "$name debe ser entero" 2
done
[[ "$MAX_ERROR_RATIO" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] || die "MAX_ERROR_RATIO debe estar entre 0 y 1" 2

WORK_DIR="$(mktemp -d)" || die "no se pudo crear directorio temporal"
trap 'rm -rf -- "$WORK_DIR"' EXIT

load_worker() {
  local id="$1" deadline="$2" out="$WORK_DIR/worker-$1" code path
  local -a paths=(/api/orders /actuator/health/readiness /api/orders/status/PENDING /api/orders/9223372036854775807)
  : >"$out"
  while (( $(date +%s) < deadline )); do
    path="${paths[$((RANDOM % ${#paths[@]}))]}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL$path" || true)"
    printf '%s\n' "${code:-000}" >>"$out"
  done
}

generate_load() {
  local deadline i
  deadline=$(( $(date +%s) + LOAD_SECONDS ))
  log_info "generando carga durante ${LOAD_SECONDS}s con $LOAD_CONCURRENCY clientes contra $BASE_URL"
  for (( i = 1; i <= LOAD_CONCURRENCY; i++ )); do
    load_worker "$i" "$deadline" &
  done
  wait
  CLIENT_TOTAL="$(cat "$WORK_DIR"/worker-* | wc -l)"
  CLIENT_ERRORS="$(cat "$WORK_DIR"/worker-* | grep -cE '^(5..|000)$' || true)"
  log_info "cliente: $CLIENT_TOTAL solicitudes, $CLIENT_ERRORS con error 5xx o sin respuesta"
}

prom_query() {
  local query="$1" response
  response="$(curl -sS --max-time 15 --get --data-urlencode "query=$query" "$PROM_URL/api/v1/query")" \
    || die "Prometheus no responde en $PROM_URL"
  [[ "$(jq -r '.status' <<<"$response")" == "success" ]] || die "consulta invalida: $query -> $response"
  jq -r '.data.result[0].value[1] // "0"' <<<"$response"
}

within() {
  awk -v v="$1" -v max="$2" 'BEGIN { exit !(v != "NaN" && v + 0 <= max + 0) }'
}

generate_load
log_info "esperando ${SCRAPE_WAIT}s para la recoleccion de metricas"
sleep "$SCRAPE_WAIT"

WINDOW="$(( LOAD_SECONDS + SCRAPE_WAIT + 30 ))s"
SELECTOR="reporter=\"destination\",destination_workload_namespace=\"$APP_NAMESPACE\",destination_workload=\"order-manager\",destination_canonical_revision=\"$REVISION\""
TOTAL="$(prom_query "sum(increase(istio_requests_total{$SELECTOR}[$WINDOW]))")"
ERRORS="$(prom_query "sum(increase(istio_requests_total{$SELECTOR,response_code=~\"5..\"}[$WINDOW])) or vector(0)")"
PODS="$(prom_query "count(sum by (pod) (increase(istio_requests_total{$SELECTOR}[$WINDOW])) > 0) or vector(0)")"
P95="$(prom_query "histogram_quantile(0.95, sum by (le) (rate(istio_request_duration_milliseconds_bucket{$SELECTOR}[$WINDOW])))")"
RATIO="$(awk -v e="$ERRORS" -v t="$TOTAL" 'BEGIN { if (t + 0 > 0) printf "%.4f", e / t; else print "1" }')"

RESULTS=()
FAILED=0
evaluate() {
  local name="$1" value="$2" limit="$3" ok="$4"
  if [[ "$ok" == "true" ]]; then
    RESULTS+=("| PASS | $name | $value | $limit |")
  else
    RESULTS+=("| FAIL | $name | $value | $limit |")
    FAILED=$((FAILED + 1))
  fi
  printf '[%s] %s: %s (limite %s)\n' "$([[ "$ok" == true ]] && echo PASS || echo FAIL)" "$name" "$value" "$limit"
}

evaluate "Solicitudes observadas por Istio" "$(printf '%.0f' "$TOTAL")" ">= $MIN_REQUESTS" \
  "$(awk -v v="$TOTAL" -v m="$MIN_REQUESTS" 'BEGIN { print (v + 0 >= m + 0) ? "true" : "false" }')"
evaluate "Proporcion de errores 5xx" "$RATIO" "<= $MAX_ERROR_RATIO" \
  "$(within "$RATIO" "$MAX_ERROR_RATIO" && echo true || echo false)"
evaluate "Pods de la revision que recibieron trafico" "$PODS" ">= $EXPECTED_REPLICAS" \
  "$(awk -v v="$PODS" -v m="$EXPECTED_REPLICAS" 'BEGIN { print (v + 0 >= m + 0) ? "true" : "false" }')"
evaluate "Latencia p95 (ms)" "$(printf '%.1f' "$P95" 2>/dev/null || echo "$P95")" "<= $MAX_P95_MS" \
  "$(within "$P95" "$MAX_P95_MS" && echo true || echo false)"
evaluate "Errores vistos por el cliente" "$CLIENT_ERRORS de $CLIENT_TOTAL" "<= $MAX_ERROR_RATIO" \
  "$(awk -v e="$CLIENT_ERRORS" -v t="$CLIENT_TOTAL" -v m="$MAX_ERROR_RATIO" 'BEGIN { print (t > 0 && e / t <= m) ? "true" : "false" }')"

summary "### Gate de SLO post-despliegue (revision \`$REVISION\`)" "" \
  "| Estado | Indicador | Valor | Limite |" "|---|---|---|---|" "${RESULTS[@]}" ""

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'requests=%s\n' "$(printf '%.0f' "$TOTAL")"
    printf 'error_ratio=%s\n' "$RATIO"
    printf 'p95_ms=%s\n' "$(printf '%.1f' "$P95" 2>/dev/null || echo 0)"
  } >>"$GITHUB_OUTPUT"
fi

(( FAILED == 0 )) || die "la revision $REVISION no cumple los SLO; se requiere rollback"
log_info "la revision $REVISION cumple los SLO"
