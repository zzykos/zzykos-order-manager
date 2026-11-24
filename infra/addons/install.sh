#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: infra/addons/install.sh

Instala los complementos de observabilidad de Istio en la misma version que istioctl
(Prometheus, Grafana, Kiali y Jaeger), las reglas de grabacion y alertas del proyecto,
el Pushgateway para metricas del pipeline CI/CD y el dashboard de Grafana.

Variables de entorno:
  EXPOSE_KIALI_LB   true para publicar Kiali con un Service LoadBalancer (por defecto false)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 0 )) || { usage >&2; exit 2; }

load_versions
require_cmd kubectl curl

EXPOSE_KIALI_LB="${EXPOSE_KIALI_LB:-false}"
ADDONS_URL="https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons"

kubectl get namespace "$MESH_NAMESPACE" >/dev/null || die "namespace $MESH_NAMESPACE no existe: instalar Istio primero"

for addon in prometheus grafana jaeger kiali; do
  log_info "aplicando complemento $addon ($ISTIO_VERSION)"
  kubectl apply -f "$ADDONS_URL/$addon.yaml" || die "no se pudo aplicar $addon"
done

kubectl -n "$MESH_NAMESPACE" patch configmap prometheus --type merge \
  --patch-file "$REPO_ROOT/observability/prometheus/rules-patch.yaml" \
  || die "no se pudieron aplicar las reglas de Prometheus"

kubectl apply -f "$REPO_ROOT/observability/pushgateway/pushgateway.yaml" || die "no se pudo aplicar el Pushgateway"

for deployment in prometheus grafana jaeger kiali pushgateway; do
  kubectl -n "$MESH_NAMESPACE" rollout status "deployment/$deployment" --timeout=300s \
    || die "el complemento $deployment no quedo disponible"
done

if [[ "$EXPOSE_KIALI_LB" == "true" ]]; then
  log_warn "Kiali quedara expuesto publicamente mediante un balanceador de AWS"
  kubectl apply -f "$REPO_ROOT/observability/kiali/kiali-lb.yaml" || die "no se pudo crear kiali-lb"
fi

"$REPO_ROOT/scripts/import-grafana-dashboard.sh"

kubectl -n "$MESH_NAMESPACE" get pods,svc
log_info "complementos instalados; acceso local con scripts/port-forward.sh"
