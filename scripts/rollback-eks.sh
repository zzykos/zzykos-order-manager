#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: rollback-eks.sh

Revierte el Deployment order-manager a la revision anterior y espera a que quede estable.
Si no existe una revision previa, escala el Deployment a 0 para no dejar en servicio
una version que no supero la verificacion.
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 0 )) || { usage >&2; exit 2; }

load_versions
require_cmd kubectl jq

REVISIONS="$(kubectl -n "$APP_NAMESPACE" get replicasets \
  -l app.kubernetes.io/name=order-manager -o json \
  | jq '[.items[].metadata.annotations["deployment.kubernetes.io/revision"] | tonumber] | length')" \
  || die "no se pudieron consultar las revisiones del Deployment"

if (( REVISIONS < 2 )); then
  log_warn "no hay revision previa; se escala order-manager a 0 para aislar la version defectuosa"
  kubectl -n "$APP_NAMESPACE" scale deployment/order-manager --replicas=0 || die "no se pudo escalar a 0"
  exit 0
fi

kubectl -n "$APP_NAMESPACE" rollout undo deployment/order-manager || die "rollout undo fallo"
kubectl -n "$APP_NAMESPACE" rollout status deployment/order-manager --timeout=300s \
  || die "la revision anterior no quedo disponible"
kubectl -n "$APP_NAMESPACE" rollout history deployment/order-manager | tail -n 5
log_info "rollback completado: $(kubectl -n "$APP_NAMESPACE" get deployment order-manager \
  -o jsonpath='{.spec.template.metadata.labels.app\.kubernetes\.io/version}')"
