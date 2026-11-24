# Fase 11: Observabilidad en EKS con Istio, Kiali, Prometheus y CloudWatch

En esta fase llevamos `order-manager` desde el entorno simulado con Docker Compose a un clúster real de Amazon EKS. Encima del clúster montamos una malla de servicios Istio y un stack de observabilidad que cubre los tres pilares: métricas, logs y trazas. También conectamos el pipeline CI/CD a ese stack, de modo que cada ejecución deja sus propias métricas junto a las del microservicio en ejecución.

## Arquitectura

```text
GitHub Actions (ci-cd.yml)
  ├─ pruebas, SAST, SCA, políticas, auditoría, imagen
  ├─ deploy-eks.yml ──► kubectl apply (Kustomize) ──► verificación ──► rollback si falla
  └─ push-cicd-metrics.sh ──► Pushgateway

EKS cluster-istio (us-east-1, nodos t3.medium, rol LabRole)
  istio-system
    istiod · istio-ingressgateway · istio-cni-node
    Prometheus ◄── sidecars Envoy, métricas de la app, cAdvisor, Pushgateway
    Grafana (dashboard "Order Manager - DevOps")
    Kiali (grafo de la malla, mTLS, validación de configuración)
    Jaeger (trazas distribuidas, receptor Zipkin)
    Pushgateway (métricas del pipeline CI/CD)
  order-manager (istio-injection=enabled, Pod Security restricted)
    order-manager x2..6 (app + istio-proxy) ──mTLS──► postgres (app + istio-proxy)
  amazon-cloudwatch
    CloudWatch Agent (Container Insights) · Fluent Bit ──► CloudWatch Logs
CloudWatch: alarmas ──► SNS ──► correo del equipo
```

| Componente | Qué aporta | Dónde se configura |
|---|---|---|
| Istio 1.31.4 (perfil `demo`, CNI) | mTLS, autorización, enrutamiento, reintentos, métricas L7 y trazas sin modificar el código | `infra/istio/istio-operator.yaml` |
| Prometheus | Almacena las métricas de Envoy, de la JVM y de cAdvisor, y las del pipeline | `observability/prometheus/rules-patch.yaml` |
| Grafana | Dashboard que une métricas de CI/CD y de ejecución | `observability/grafana/dashboards/order-manager-devops.json` |
| Kiali | Grafo de tráfico, estado de mTLS y validación de los recursos de Istio | complemento de Istio; `observability/kiali/kiali-lb.yaml` como exposición opcional |
| Jaeger | Recorrido de cada solicitud: gateway, `order-manager` y `postgres` | `meshConfig.extensionProviders` y `k8s/istio/telemetry.yaml` |
| CloudWatch Container Insights | CPU, memoria, reinicios y pods disponibles a nivel de nodo y de pod | complemento `amazon-cloudwatch-observability` |
| CloudWatch Logs y Fluent Bit | Logs centralizados de la aplicación (JSON ECS) y access logs de Envoy | `observability/cloudwatch/setup.sh` |
| SNS | Notificación por correo de las alarmas | `observability/cloudwatch/setup.sh` |

## Decisiones de diseño

- **Istio CNI en lugar del init container privilegiado.** El namespace `order-manager` aplica el Pod Security Standard `restricted`, que no admite las capacidades `NET_ADMIN` y `NET_RAW` del `istio-init` tradicional. Con el plugin CNI, la configuración de iptables corre en el nodo y los pods siguen cumpliendo `restricted`.
- **Misma versión para `istioctl` y los complementos.** El material de clase mezcla `istioctl` 1.26.2 con complementos de `release-1.20`. Nosotros fijamos `ISTIO_VERSION` en `infra/versions.conf`, e instalamos los complementos desde el tag correspondiente.
- **Acceso por `port-forward`.** El ingress gateway se crea como `ClusterIP` y las consolas se abren con `scripts/port-forward.sh`. Así no hay balanceadores públicos ni costos adicionales. Si hace falta, `observability/kiali/kiali-lb.yaml` publica Kiali con un balanceador de AWS.
- **Fusión de métricas de Istio.** El pod declara `prometheus.io/*` apuntando a `/actuator/prometheus`. El sidecar une esas métricas con las de Envoy en el puerto 15020, de modo que Prometheus obtiene en un solo scrape las métricas de negocio, las de la JVM y las de la malla, sin exponer Actuator fuera del pod.
- **Logs estructurados.** El perfil `docker` emite logs en formato ECS (`logging.structured.format.console=ecs`). Fluent Bit los envía a `/aws/containerinsights/cluster-istio/application`, y un filtro de métricas cuenta los eventos `ERROR`.
- **Learner Lab.** El clúster y los nodos usan el rol existente `LabRole` (`iam.serviceRoleARN` e `instanceRoleARN`), sin OIDC ni roles nuevos. Las credenciales son temporales: tanto los scripts como el pipeline validan la identidad antes de operar y muestran un error explícito si expiraron.

## Puesta en marcha

```bash
./scripts/install-tools.sh istioctl kustomize conftest eksctl

export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...
./infra/eks/create-cluster.sh
./infra/istio/install.sh
./infra/addons/install.sh
ALERT_EMAIL=equipo@example.com ./observability/cloudwatch/setup.sh

IMAGE=ghcr.io/zzykos/zzykos-order-manager:<sha> GIT_COMMIT=<sha> ./scripts/deploy-eks.sh apply
EXPECTED_COMMIT=<sha> ./scripts/post-deploy-verify.sh

./scripts/port-forward.sh
```

| Consola | URL local |
|---|---|
| Kiali | http://127.0.0.1:20001 |
| Grafana | http://127.0.0.1:3000 |
| Prometheus | http://127.0.0.1:9090 |
| Jaeger | http://127.0.0.1:16686 |
| API (vía ingress gateway) | http://127.0.0.1:8080/api/orders |

Al terminar la práctica liberamos todo en orden: aplicación y servicios, complementos, Istio, CloudWatch y SNS y, al final, el clúster. Esto lo hace `./infra/cleanup.sh`.

## Métricas por pilar

| Pilar | Señal | Fuente | Uso |
|---|---|---|---|
| Métricas | Solicitudes por segundo, códigos de respuesta, latencia p50/p95/p99 | `istio_requests_total`, `istio_request_duration_milliseconds` | Disponibilidad y SLO |
| Métricas | CPU y memoria por contenedor (aplicación y sidecar) | cAdvisor, Container Insights | Dimensionamiento de `requests`/`limits` y del HPA |
| Métricas | Heap de la JVM, errores HTTP por endpoint | Micrometer (`jvm_memory_used_bytes`, `http_server_requests_seconds`) | Diagnóstico de la aplicación |
| Métricas | Errores registrados | `logback_events_total{level="error"}`, `OrderManager/ErrorLogCount` | Detección temprana de fallos |
| Métricas | Tiempo de despliegue, cobertura, pruebas, vulnerabilidades, resultado del pipeline | Pushgateway (`cicd_*`) | Salud del proceso de entrega |
| Logs | Logs JSON de la aplicación y access logs de Envoy | CloudWatch Logs (Logs Insights) | Investigación de incidentes |
| Trazas | Spans de gateway, `order-manager` y `postgres` | Jaeger, enlazado desde Kiali | Ubicar dónde se acumula la latencia |

Las reglas de grabación (`order_manager:*`) precalculan la disponibilidad, la tasa de errores, la latencia p95, la CPU y la memoria. Las usan el dashboard, las alertas y el gate de SLO, así que los tres trabajan con la misma definición de cada indicador.

## Dashboard "Order Manager - DevOps"

Lo versionamos como código y el pipeline lo sincroniza en cada despliegue (`scripts/import-grafana-dashboard.sh`). Tiene dos secciones:

1. **Pipeline CI/CD:** resultado del último pipeline, cobertura frente al umbral de 80 %, tiempo del último despliegue y su evolución, pruebas ejecutadas y fallidas, vulnerabilidades HIGH/CRITICAL de la imagen, y una tabla de trazabilidad con el commit, la imagen, la ejecución y si hubo rollback. Cada despliegue aparece como anotación en todos los gráficos.
2. **Microservicio en ejecución:** disponibilidad, RPS, latencia p95, réplicas activas, errores registrados, proporción de tráfico mTLS, solicitudes por código, latencia por percentil, tasa de 5xx, errores en logs por nivel, errores HTTP por endpoint, CPU y memoria por contenedor, y heap de la JVM.

En CloudWatch mantenemos un segundo dashboard (`order-manager-cluster-istio`) con la vista de infraestructura: CPU de los nodos con el umbral de la alarma, CPU y memoria del pod, pods en ejecución, reinicios, errores contados desde los logs y consultas de Logs Insights para los últimos errores y las respuestas 5xx de Envoy.

## Alertas

| Alerta | Condición | Severidad | Canal |
|---|---|---|---|
| `OrderManagerAvailabilityBelowSLO` | Disponibilidad < 99 % durante 5 min | crítica | Prometheus y Grafana |
| `OrderManagerHighLatencyP95` | p95 > 1 s durante 10 min | advertencia | Prometheus y Grafana |
| `OrderManagerNoHealthyTargets` | Ninguna réplica entrega métricas durante 2 min | crítica | Prometheus y Grafana |
| `OrderManagerErrorLogs` | Más de 10 eventos ERROR en 10 min | advertencia | Prometheus y Grafana |
| `OrderManagerMemoryNearLimit` | Memoria > 90 % del límite durante 10 min | advertencia | Prometheus y Grafana |
| `CicdPipelineBlocked`, `CicdCoverageBelowThreshold`, `CicdDeploymentRolledBack` | Estado del pipeline | advertencia o crítica | Prometheus y Grafana |
| `cluster-istio-node-cpu-high` | CPU máxima de nodo >= 80 % en 5 min | crítica | CloudWatch, SNS y correo |
| `order-manager-pod-cpu-high` | CPU del pod >= 80 % de su límite durante 10 min | advertencia | CloudWatch, SNS y correo |
| `order-manager-container-restarts` | Al menos 1 reinicio en 5 min | advertencia | CloudWatch, SNS y correo |
| `order-manager-unavailable` | Sin pods en ejecución durante 3 min | crítica | CloudWatch, SNS y correo |
| `order-manager-error-logs` | 5 o más eventos ERROR en 5 min | advertencia | CloudWatch, SNS y correo |

## Cómo estas señales guían nuestras decisiones técnicas

| Señal observada | Decisión que habilita |
|---|---|
| El gate de SLO detecta más de 1 % de errores 5xx o p95 > 1 s en la revisión nueva | Revertimos el despliegue automáticamente y analizamos la revisión con las trazas de Jaeger antes de reintentar |
| CPU por contenedor sostenida cerca del objetivo del HPA (70 %) | Ajustamos `requests`, `maxReplicas` o el tipo de instancia del grupo de nodos |
| Memoria del sidecar o de la JVM cerca del límite | Revisamos `MaxRAMPercentage` y los límites del proxy en `istio-operator.yaml` |
| Aumento del tiempo de despliegue entre ejecuciones | Revisamos el tamaño de la imagen, las sondas de arranque y la capacidad del clúster |
| La cobertura baja hacia el 80 % | Priorizamos pruebas en el siguiente incremento antes de agregar funcionalidad |
| Vulnerabilidades HIGH/CRITICAL que bloquean la imagen | Actualizamos la dependencia o la imagen base, o documentamos una excepción con fecha de expiración en `.trivyignore.yaml` |
| Tráfico sin mTLS o aristas rojas en Kiali | Revisamos `PeerAuthentication`, `DestinationRule` y `AuthorizationPolicy` con la validación de Kiali y `istioctl analyze` |
