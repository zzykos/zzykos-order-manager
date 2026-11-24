#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: post-deploy-verify.sh

Verificacion posterior al despliegue en EKS: politicas de la malla, pruebas de humo a traves
del ingress gateway de Istio y gate de SLO con metricas de Prometheus.

Variables de entorno:
  EXPECTED_COMMIT     Commit que debe reportar /actuator/info (obligatoria)
  REVISION            Revision desplegada (por defecto los primeros 12 caracteres del commit)
  EXPECTED_REPLICAS   Replicas que deben responder (por defecto 2)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 0 )) || { usage >&2; exit 2; }

load_versions
require_cmd kubectl curl jq
require_env EXPECTED_COMMIT

export REVISION="${REVISION:-${EXPECTED_COMMIT:0:12}}"
export EXPECTED_COMMIT
export EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-2}"
export GATEWAY_KIND=istio

trap stop_port_forwards EXIT

"$REPO_ROOT/scripts/verify-mesh.sh"

start_port_forward "$MESH_NAMESPACE" svc/istio-ingressgateway 18080:80 || die "sin acceso al ingress gateway"
start_port_forward "$MESH_NAMESPACE" svc/prometheus 19090:9090 || die "sin acceso a Prometheus"

"$REPO_ROOT/scripts/smoke-test.sh" "http://127.0.0.1:18080"
"$REPO_ROOT/scripts/slo-gate.sh" "http://127.0.0.1:18080" "http://127.0.0.1:19090"
