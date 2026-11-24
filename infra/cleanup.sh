#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: infra/cleanup.sh [--yes] [--keep-cluster] [--keep-cloudwatch]

Elimina los recursos en el orden correcto para no dejar costos activos:
aplicacion y balanceadores, complementos, Istio, recursos de CloudWatch/SNS y el cluster EKS.

  --yes              No solicita confirmacion
  --keep-cluster     Conserva el cluster EKS y su red
  --keep-cloudwatch  Conserva alarmas, dashboard, filtro de metricas y tema SNS
USAGE
}

ASSUME_YES=false
KEEP_CLUSTER=false
KEEP_CLOUDWATCH=false
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=true ;;
    --keep-cluster) KEEP_CLUSTER=true ;;
    --keep-cloudwatch) KEEP_CLOUDWATCH=true ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

load_versions
require_cmd kubectl aws

if [[ "$ASSUME_YES" != "true" ]]; then
  printf 'Se eliminaran los recursos de %s en %s (cluster conservado: %s). Escribir el nombre del cluster para confirmar: ' \
    "$CLUSTER_NAME" "$AWS_REGION" "$KEEP_CLUSTER" >&2
  read -r answer
  [[ "$answer" == "$CLUSTER_NAME" ]] || die "confirmacion incorrecta; no se elimino nada" 1
fi

ADDONS_URL="https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons"
ERRORS=0

attempt() {
  local description="$1"
  shift
  if "$@"; then
    log_info "$description"
  else
    log_warn "fallo: $description"
    ERRORS=$((ERRORS + 1))
  fi
}

if kubectl get nodes >/dev/null 2>&1; then
  attempt "namespace de la aplicacion eliminado" kubectl delete namespace "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=300s
  attempt "kiali-lb eliminado" kubectl delete -f "$REPO_ROOT/observability/kiali/kiali-lb.yaml" --ignore-not-found
  attempt "Pushgateway eliminado" kubectl delete -f "$REPO_ROOT/observability/pushgateway/pushgateway.yaml" --ignore-not-found
  for addon in kiali jaeger grafana prometheus; do
    attempt "complemento $addon eliminado" kubectl delete -f "$ADDONS_URL/$addon.yaml" --ignore-not-found
  done
  if command -v istioctl >/dev/null 2>&1; then
    attempt "Istio desinstalado" istioctl uninstall -y --purge
  else
    log_warn "istioctl no disponible; se omite la desinstalacion de Istio"
    ERRORS=$((ERRORS + 1))
  fi
  attempt "namespace $MESH_NAMESPACE eliminado" kubectl delete namespace "$MESH_NAMESPACE" --ignore-not-found --wait=true --timeout=300s
else
  log_warn "sin acceso al cluster; se omiten los recursos de Kubernetes"
fi

if [[ "$KEEP_CLOUDWATCH" != "true" ]]; then
  AWS=(aws --region "$AWS_REGION")
  attempt "alarmas de CloudWatch eliminadas" "${AWS[@]}" cloudwatch delete-alarms --alarm-names \
    "${CLUSTER_NAME}-node-cpu-high" order-manager-pod-cpu-high order-manager-container-restarts \
    order-manager-unavailable order-manager-error-logs
  attempt "dashboard de CloudWatch eliminado" "${AWS[@]}" cloudwatch delete-dashboards \
    --dashboard-names "order-manager-${CLUSTER_NAME}"
  TOPIC_ARN="$("${AWS[@]}" sns list-topics --query "Topics[?ends_with(TopicArn, ':order-manager-alertas')].TopicArn | [0]" --output text 2>/dev/null || true)"
  if [[ -n "$TOPIC_ARN" && "$TOPIC_ARN" != "None" ]]; then
    attempt "tema SNS eliminado" "${AWS[@]}" sns delete-topic --topic-arn "$TOPIC_ARN"
  fi
fi

if [[ "$KEEP_CLUSTER" != "true" ]]; then
  require_cmd eksctl
  attempt "cluster $CLUSTER_NAME eliminado (nodos, red y stacks de CloudFormation)" \
    eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
fi

(( ERRORS == 0 )) || die "limpieza finalizada con $ERRORS errores; revisar EC2 > Load Balancers e Instances"
log_info "limpieza completa; verificar en la consola que no queden balanceadores ni instancias"
