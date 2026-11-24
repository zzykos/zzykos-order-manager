#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: port-forward.sh [all|kiali|grafana|prometheus|jaeger|pushgateway|app]...

Abre tuneles locales (kubectl port-forward) hacia las consolas de observabilidad y la API,
sin exponer servicios publicamente. Se mantienen activos hasta presionar Ctrl+C.

  kiali        http://127.0.0.1:20001
  grafana      http://127.0.0.1:3000
  prometheus   http://127.0.0.1:9090
  jaeger       http://127.0.0.1:16686
  pushgateway  http://127.0.0.1:9091
  app          http://127.0.0.1:8080  (API a traves del ingress gateway de Istio)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

load_versions
require_cmd kubectl

TARGETS=("$@")
(( ${#TARGETS[@]} > 0 )) || TARGETS=(all)
if [[ " ${TARGETS[*]} " == *" all "* ]]; then
  TARGETS=(kiali grafana prometheus jaeger pushgateway app)
fi

trap stop_port_forwards EXIT INT TERM

for target in "${TARGETS[@]}"; do
  case "$target" in
    kiali) start_port_forward "$MESH_NAMESPACE" svc/kiali 20001:20001 ;;
    grafana) start_port_forward "$MESH_NAMESPACE" svc/grafana 3000:3000 ;;
    prometheus) start_port_forward "$MESH_NAMESPACE" svc/prometheus 9090:9090 ;;
    jaeger) start_port_forward "$MESH_NAMESPACE" svc/tracing 16686:80 ;;
    pushgateway) start_port_forward "$MESH_NAMESPACE" svc/pushgateway 9091:9091 ;;
    app) start_port_forward "$MESH_NAMESPACE" svc/istio-ingressgateway 8080:80 ;;
    *) usage >&2; die "destino desconocido: $target" 2 ;;
  esac || die "no se pudo abrir el tunel hacia $target"
done

log_info "tuneles activos; Ctrl+C para cerrarlos"
wait
