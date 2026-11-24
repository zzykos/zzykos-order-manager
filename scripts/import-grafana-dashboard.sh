#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: import-grafana-dashboard.sh [ARCHIVO_JSON...]

Importa (o actualiza) dashboards de Grafana mediante su API HTTP. Si no se indican
archivos, importa todos los de observability/grafana/dashboards.

Variables de entorno:
  GRAFANA_URL   URL de Grafana (por defecto abre un port-forward a istio-system/svc/grafana)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

load_versions
require_cmd curl jq

FILES=("$@")
if (( ${#FILES[@]} == 0 )); then
  FILES=("$REPO_ROOT"/observability/grafana/dashboards/*.json)
fi

if [[ -z "${GRAFANA_URL:-}" ]]; then
  require_cmd kubectl
  trap stop_port_forwards EXIT
  start_port_forward "$MESH_NAMESPACE" svc/grafana 13000:3000 || die "no se pudo abrir port-forward a Grafana"
  GRAFANA_URL="http://127.0.0.1:13000"
fi
GRAFANA_URL="${GRAFANA_URL%/}"

for file in "${FILES[@]}"; do
  [[ -r "$file" ]] || die "no se puede leer el dashboard $file" 2
  payload="$(jq -c '{dashboard: (. + {id: null}), overwrite: true, message: "importado por import-grafana-dashboard.sh"}' "$file")" \
    || die "JSON invalido en $file"
  response="$(curl -sS --max-time 20 -w '\n%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data-binary "$payload" \
    "$GRAFANA_URL/api/dashboards/db")" || die "no se pudo contactar a Grafana en $GRAFANA_URL"
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ "$code" == "200" ]] || die "Grafana rechazo $file (HTTP $code): $body"
  log_info "dashboard importado: $(jq -r '.url // .uid' <<<"$body")"
done
