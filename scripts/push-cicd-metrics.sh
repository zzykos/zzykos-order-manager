#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: push-cicd-metrics.sh pipeline|deploy

Publica metricas del pipeline CI/CD en el Pushgateway del cluster para que Prometheus
las almacene y Grafana las muestre junto a las metricas de ejecucion.

pipeline  Calidad y seguridad del pipeline completo.
          PIPELINE_SUCCESS (true|false), COVERAGE (ej. 94.6%), TESTS, TEST_FAILURES,
          VULN_CRITICAL, VULN_HIGH
deploy    Resultado del despliegue en un entorno.
          DEPLOY_ENV, DEPLOY_SUCCESS (true|false), DEPLOY_DURATION (segundos), ROLLED_BACK (true|false), IMAGE

Comunes:  GIT_COMMIT (obligatoria), RUN_ID (por defecto GITHUB_RUN_ID),
          PUSHGATEWAY_URL (por defecto abre port-forward a istio-system/svc/pushgateway)
USAGE
}

MODE="${1:-}"
case "$MODE" in
  pipeline | deploy) ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

load_versions
require_cmd curl
require_env GIT_COMMIT
RUN_ID="${RUN_ID:-${GITHUB_RUN_ID:-local}}"
JOB_NAME="order-manager-cicd"

bool_to_int() {
  case "$1" in
    true | 1) printf '1' ;;
    false | 0) printf '0' ;;
    *) die "valor booleano invalido: '$1'" 2 ;;
  esac
}

number_or_empty() {
  local value="${1:-}"
  value="${value%\%}"
  if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$value"
  fi
}

label_value() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "${v//$'\n'/ }"
}

PAYLOAD="$(mktemp)" || die "no se pudo crear archivo temporal"
trap 'rm -f -- "$PAYLOAD"; stop_port_forwards' EXIT

metric() {
  local name="$1" help="$2" value="$3" labels="${4:-}"
  [[ -n "$value" ]] || return 0
  printf '# HELP %s %s\n# TYPE %s gauge\n%s%s %s\n' "$name" "$help" "$name" "$name" "${labels:+{$labels\}}" "$value" >>"$PAYLOAD"
}

build_pipeline() {
  local coverage tests failures critical high
  coverage="$(number_or_empty "${COVERAGE:-}")"
  [[ -n "$coverage" ]] && coverage="$(awk -v c="$coverage" 'BEGIN { printf "%.4f", c / 100 }')"
  tests="$(number_or_empty "${TESTS:-}")"
  failures="$(number_or_empty "${TEST_FAILURES:-}")"
  critical="$(number_or_empty "${VULN_CRITICAL:-}")"
  high="$(number_or_empty "${VULN_HIGH:-}")"
  ENVIRONMENT="pipeline"
  metric cicd_pipeline_success "1 si todas las etapas obligatorias del pipeline fueron exitosas" "$(bool_to_int "${PIPELINE_SUCCESS:?PIPELINE_SUCCESS requerido}")"
  metric cicd_test_coverage_ratio "Cobertura de lineas JaCoCo (0 a 1)" "$coverage"
  metric cicd_tests_total "Pruebas JUnit ejecutadas" "$tests"
  metric cicd_tests_failed "Pruebas JUnit fallidas o con error" "$failures"
  {
    printf '# HELP cicd_image_vulnerabilities Vulnerabilidades de la imagen detectadas por Trivy\n# TYPE cicd_image_vulnerabilities gauge\n'
    [[ -n "$critical" ]] && printf 'cicd_image_vulnerabilities{severity="CRITICAL"} %s\n' "$critical"
    [[ -n "$high" ]] && printf 'cicd_image_vulnerabilities{severity="HIGH"} %s\n' "$high"
    true
  } >>"$PAYLOAD"
  metric cicd_pipeline_timestamp_seconds "Fin de la ejecucion del pipeline" "$(date +%s)"
  metric cicd_pipeline_info "Commit y ejecucion del ultimo pipeline" 1 \
    "commit=\"$(label_value "$GIT_COMMIT")\",run_id=\"$(label_value "$RUN_ID")\""
}

build_deploy() {
  local duration
  require_env DEPLOY_ENV DEPLOY_SUCCESS
  [[ "$DEPLOY_ENV" =~ ^[a-z0-9-]+$ ]] || die "DEPLOY_ENV invalido: $DEPLOY_ENV" 2
  duration="$(number_or_empty "${DEPLOY_DURATION:-}")"
  ENVIRONMENT="$DEPLOY_ENV"
  metric cicd_deploy_success "1 si el despliegue supero la verificacion posterior" "$(bool_to_int "$DEPLOY_SUCCESS")"
  metric cicd_deploy_duration_seconds "Duracion del despliegue y su verificacion" "$duration"
  metric cicd_deploy_rolled_back "1 si el despliegue fue revertido automaticamente" "$(bool_to_int "${ROLLED_BACK:-false}")"
  metric cicd_last_deploy_timestamp_seconds "Momento del ultimo despliegue" "$(date +%s)"
  metric cicd_deploy_info "Trazabilidad del ultimo despliegue" 1 \
    "commit=\"$(label_value "$GIT_COMMIT")\",image=\"$(label_value "${IMAGE:-desconocida}")\",run_id=\"$(label_value "$RUN_ID")\",rolled_back=\"$(label_value "${ROLLED_BACK:-false}")\""
}

"build_$MODE"

if [[ -z "${PUSHGATEWAY_URL:-}" ]]; then
  require_cmd kubectl
  start_port_forward "$MESH_NAMESPACE" svc/pushgateway 19091:9091 || die "no se pudo abrir port-forward al Pushgateway"
  PUSHGATEWAY_URL="http://127.0.0.1:19091"
fi

URL="${PUSHGATEWAY_URL%/}/metrics/job/$JOB_NAME/stage/$MODE/environment/$ENVIRONMENT"
CODE="$(curl -sS --max-time 15 -o /dev/stderr -w '%{http_code}' -X PUT --data-binary "@$PAYLOAD" "$URL")" \
  || die "no se pudo contactar al Pushgateway en $PUSHGATEWAY_URL"
[[ "$CODE" =~ ^2 ]] || die "el Pushgateway rechazo las metricas (HTTP $CODE)"

log_info "metricas '$MODE' publicadas en $URL"
cat "$PAYLOAD" >&2
