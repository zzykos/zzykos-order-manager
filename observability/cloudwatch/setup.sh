#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: observability/cloudwatch/setup.sh

Configura Amazon CloudWatch para el cluster: complemento CloudWatch Observability
(Container Insights y Fluent Bit), retencion de logs, filtro de metricas sobre errores,
tema SNS con suscripcion por correo, alarmas y dashboard.

Variables de entorno:
  ALERT_EMAIL         Correo que recibe las alarmas (obligatoria; confirmar la suscripcion)
  SNS_TOPIC_NAME      Nombre del tema SNS (por defecto order-manager-alertas)
  LOG_RETENTION_DAYS  Retencion de CloudWatch Logs (por defecto 7)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 0 )) || { usage >&2; exit 2; }

load_versions
require_cmd aws jq envsubst
require_env ALERT_EMAIL
[[ "$ALERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "ALERT_EMAIL invalido" 2

SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-order-manager-alertas}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
APP_LOG_GROUP="/aws/containerinsights/${CLUSTER_NAME}/application"
export AWS_REGION CLUSTER_NAME APP_NAMESPACE
AWS=(aws --region "$AWS_REGION" --output json)

aws sts get-caller-identity >/dev/null 2>&1 || die "credenciales de AWS invalidas o expiradas"

ensure_addon() {
  local status
  status="$("${AWS[@]}" eks describe-addon --cluster-name "$CLUSTER_NAME" \
    --addon-name amazon-cloudwatch-observability --query 'addon.status' --output text 2>/dev/null || true)"
  if [[ -z "$status" || "$status" == "None" ]]; then
    log_info "creando complemento amazon-cloudwatch-observability"
    "${AWS[@]}" eks create-addon --cluster-name "$CLUSTER_NAME" \
      --addon-name amazon-cloudwatch-observability >/dev/null || die "no se pudo crear el complemento"
  fi
  "${AWS[@]}" eks wait addon-active --cluster-name "$CLUSTER_NAME" \
    --addon-name amazon-cloudwatch-observability || die "el complemento CloudWatch Observability no quedo activo"
  log_info "Container Insights activo"
}

ensure_log_group() {
  local found
  found="$("${AWS[@]}" logs describe-log-groups --log-group-name-prefix "$APP_LOG_GROUP" \
    --query "logGroups[?logGroupName=='$APP_LOG_GROUP'] | length(@)" --output text)" \
    || die "no se pudieron listar los log groups"
  if [[ "$found" == "0" ]]; then
    "${AWS[@]}" logs create-log-group --log-group-name "$APP_LOG_GROUP" || die "no se pudo crear $APP_LOG_GROUP"
  fi
  "${AWS[@]}" logs put-retention-policy --log-group-name "$APP_LOG_GROUP" \
    --retention-in-days "$LOG_RETENTION_DAYS" || die "no se pudo fijar la retencion de logs"
  "${AWS[@]}" logs put-metric-filter --log-group-name "$APP_LOG_GROUP" \
    --filter-name order-manager-error-logs \
    --filter-pattern '{ ($.kubernetes.namespace_name = "order-manager") && ($.kubernetes.container_name = "order-manager") && ($.log = "*\"ERROR\"*") }' \
    --metric-transformations metricName=ErrorLogCount,metricNamespace=OrderManager,metricValue=1,defaultValue=0 \
    || die "no se pudo crear el filtro de metricas de errores"
  log_info "logs de aplicacion en $APP_LOG_GROUP (retencion $LOG_RETENTION_DAYS dias, filtro ErrorLogCount)"
}

ensure_topic() {
  local existing
  TOPIC_ARN="$("${AWS[@]}" sns create-topic --name "$SNS_TOPIC_NAME" --query TopicArn --output text)" \
    || die "no se pudo crear el tema SNS"
  existing="$("${AWS[@]}" sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
    --query "Subscriptions[?Endpoint=='$ALERT_EMAIL'] | length(@)" --output text)" \
    || die "no se pudieron listar las suscripciones"
  if [[ "$existing" == "0" ]]; then
    "${AWS[@]}" sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
      --notification-endpoint "$ALERT_EMAIL" >/dev/null || die "no se pudo suscribir $ALERT_EMAIL"
    log_warn "revisar el correo $ALERT_EMAIL y confirmar la suscripcion (AWS Notification - Subscription Confirmation)"
  fi
  log_info "tema SNS: $TOPIC_ARN"
}

put_alarm() {
  local name="$1" description="$2" namespace="$3" metric="$4" stat="$5" period="$6" periods="$7" \
    comparison="$8" threshold="$9" missing="${10}"
  shift 10
  local -a dimensions=()
  if (( $# > 0 )); then
    dimensions=(--dimensions "$@")
  fi
  "${AWS[@]}" cloudwatch put-metric-alarm \
    --alarm-name "$name" \
    --alarm-description "$description" \
    --namespace "$namespace" \
    --metric-name "$metric" \
    --statistic "$stat" \
    --period "$period" \
    --evaluation-periods "$periods" \
    --datapoints-to-alarm "$periods" \
    --comparison-operator "$comparison" \
    --threshold "$threshold" \
    --treat-missing-data "$missing" \
    --alarm-actions "$TOPIC_ARN" \
    --ok-actions "$TOPIC_ARN" \
    "${dimensions[@]}" || die "no se pudo crear la alarma $name"
  log_info "alarma configurada: $name"
}

ensure_alarms() {
  local cluster="Name=ClusterName,Value=$CLUSTER_NAME" ns="Name=Namespace,Value=$APP_NAMESPACE"
  put_alarm "${CLUSTER_NAME}-node-cpu-high" \
    "CPU maxima de los nodos >= 80% durante 5 minutos" \
    ContainerInsights node_cpu_utilization Maximum 300 1 GreaterThanOrEqualToThreshold 80 notBreaching \
    "$cluster"
  put_alarm "order-manager-pod-cpu-high" \
    "CPU promedio de order-manager >= 80% de su limite durante 10 minutos" \
    ContainerInsights pod_cpu_utilization_over_pod_limit Average 300 2 GreaterThanOrEqualToThreshold 80 notBreaching \
    "$cluster" "$ns" "Name=PodName,Value=order-manager"
  put_alarm "order-manager-container-restarts" \
    "Reinicios de contenedores de order-manager en 5 minutos" \
    ContainerInsights pod_number_of_container_restarts Sum 300 1 GreaterThanOrEqualToThreshold 1 notBreaching \
    "$cluster" "$ns" "Name=PodName,Value=order-manager"
  put_alarm "order-manager-unavailable" \
    "order-manager sin pods en ejecucion" \
    ContainerInsights service_number_of_running_pods Minimum 60 3 LessThanThreshold 1 breaching \
    "$cluster" "$ns" "Name=Service,Value=order-manager"
  put_alarm "order-manager-error-logs" \
    "5 o mas eventos ERROR en logs de order-manager en 5 minutos" \
    OrderManager ErrorLogCount Sum 300 1 GreaterThanOrEqualToThreshold 5 notBreaching
}

ensure_dashboard() {
  local body
  body="$(envsubst '${AWS_REGION} ${CLUSTER_NAME} ${APP_NAMESPACE}' <"$REPO_ROOT/observability/cloudwatch/dashboard.json" | jq -c .)" \
    || die "dashboard.json invalido"
  "${AWS[@]}" cloudwatch put-dashboard --dashboard-name "order-manager-${CLUSTER_NAME}" \
    --dashboard-body "$body" >/dev/null || die "no se pudo crear el dashboard de CloudWatch"
  log_info "dashboard CloudWatch: order-manager-${CLUSTER_NAME}"
}

ensure_addon
ensure_log_group
ensure_topic
ensure_alarms
ensure_dashboard
