# Order Manager

> **Asignatura:** DOY0101 Ingeniería DevOps **Autor:** Jairo Omar Moraga Rodriguez **Repositorio Base:** [https://github.com/iam-docente/order-manager](https://github.com/iam-docente/order-manager)

Order Manager es un microservicio diseñado para la gestión de pedidos, construido como una API REST utilizando Spring Boot 3.5 y Java 25.

Este repositorio contiene no solo el código fuente de la aplicación (desarrollado inicialmente en fases previas), sino que implementa toda la infraestructura DevOps necesaria para su ciclo de vida: contenerización optimizada, un pipeline de integración y entrega continua (CI/CD), políticas de seguridad estrictas y orquestación para su despliegue.

## Índice

- [Ejecución Local](#ejecuci%C3%B3n-local)
- [API REST](#api-rest)
- [Estructura del Proyecto](#estructura-del-proyecto)
- [Arquitectura y Contenerización](#arquitectura-y-contenerizaci%C3%B3n)
- [Pipeline CI/CD](#pipeline-cicd)
- [Pruebas y Calidad de Código](#pruebas-y-calidad-de-c%C3%B3digo)
- [Seguridad y Escalabilidad](#seguridad-y-escalabilidad)
- [Trazabilidad y Despliegue](#trazabilidad-y-despliegue)
- [Orquestación](#orquestaci%C3%B3n)
- [Service Mesh en Amazon EKS (Istio y Kiali)](#service-mesh-en-amazon-eks-istio-y-kiali)
- [Monitoreo, Métricas y Dashboards](#monitoreo-m%C3%A9tricas-y-dashboards)
- [Políticas de Cumplimiento y Auditoría](#pol%C3%ADticas-de-cumplimiento-y-auditor%C3%ADa)
- [Detención Automática del Pipeline](#detenci%C3%B3n-autom%C3%A1tica-del-pipeline)
- [Configuración del Repositorio y del Clúster](#configuraci%C3%B3n-del-repositorio-y-del-cl%C3%BAster)
- [Evidencias del Proyecto](#evidencias-del-proyecto)
- [Declaración de uso de IA](#declaraci%C3%B3n-de-uso-de-ia)
- [Conclusiones y Reflexión Individual](#conclusiones-y-reflexi%C3%B3n-individual)

## Ejecución Local

### Requisitos

|Herramienta|Versión|
|---|---|
|Java (JDK)|25|
|Maven|3.9 o superior|
|Docker|24 o superior, con Docker Compose v2|

### Variables de entorno

Se definen en `.env` a partir de `.env.example`:

|Variable|Descripción|Valor de ejemplo|
|---|---|---|
|`DB_NAME`|Nombre de la base de datos PostgreSQL|`orderdb`|
|`DB_USER`|Usuario de la base de datos|`orders`|
|`DB_PASSWORD`|Contraseña de la base de datos (cambiarla)|`cambiar-esta-clave`|
|`DB_POOL_SIZE`|Tamaño máximo del pool de conexiones (HikariCP)|`10`|
|`APP_REPLICAS`|Cantidad de réplicas de la aplicación detrás del gateway|`2`|
|`HTTP_PORT`|Puerto expuesto por el gateway Nginx|`8098`|

### Opción 1: infraestructura completa con Docker Compose

```bash
# 1. Correr las pruebas localmente
mvn test

# 2. Configurar variables de entorno
cp .env.example .env

# 3. Construir la imagen y levantar la infraestructura
docker compose up -d --build

# 4. Verificar que el servicio responde a través del gateway
curl http://localhost:8098/actuator/health

# 5. Ejecutar las pruebas de humo
./scripts/smoke-test.sh http://localhost:8098

# 6. Detener todo y eliminar el volumen de la base de datos
docker compose down -v
```

La API queda disponible en `http://localhost:8098` (o en el puerto definido en `HTTP_PORT`).

### Opción 2: solo la aplicación, sin Docker

El perfil por defecto usa una base de datos H2 en memoria, por lo que no requiere PostgreSQL:

```bash
mvn spring-boot:run
```

La API queda disponible en `http://localhost:8098` y la consola de H2 en `http://localhost:8098/h2-console`.

## API REST

Todos los endpoints de negocio están bajo `/api/orders`. Un pedido pasa por los estados `PENDING` → `CONFIRMED` → `SHIPPED` → `DELIVERED`, y puede pasar a `CANCELLED`.

|Método|Ruta|Descripción|
|---|---|---|
|`GET`|`/api/orders`|Lista todos los pedidos|
|`GET`|`/api/orders/{id}`|Obtiene un pedido por su ID|
|`GET`|`/api/orders/status/{status}`|Lista los pedidos en un estado dado|
|`POST`|`/api/orders`|Crea un pedido (responde `201 Created`)|
|`POST`|`/api/orders/{id}/items`|Agrega un ítem a un pedido|
|`PUT`|`/api/orders/{id}/confirm`|Confirma el pedido|
|`PUT`|`/api/orders/{id}/ship`|Marca el pedido como enviado|
|`PUT`|`/api/orders/{id}/deliver`|Marca el pedido como entregado|
|`PUT`|`/api/orders/{id}/cancel`|Cancela el pedido|
|`DELETE`|`/api/orders/{id}`|Elimina el pedido (responde `204 No Content`)|
|`GET`|`/actuator/health`|Estado de salud del servicio|
|`GET`|`/actuator/info`|Versión y commit desplegado|

**Validaciones:** `customerName` es obligatorio (máximo 100 caracteres). En cada ítem, `productName` es obligatorio (máximo 150 caracteres), `quantity` debe estar entre 1 y 1000, y `unitPrice` debe ser mayor a 0.

### Ejemplos

Crear un pedido:

```bash
curl -X POST http://localhost:8098/api/orders \
  -H "Content-Type: application/json" \
  -d '{
        "customerName": "Ana Pérez",
        "items": [
          { "productName": "Teclado", "quantity": 2, "unitPrice": 15990 }
        ]
      }'
```

Agregar un ítem y confirmar el pedido:

```bash
curl -X POST http://localhost:8098/api/orders/1/items \
  -H "Content-Type: application/json" \
  -d '{ "productName": "Mouse", "quantity": 1, "unitPrice": 8990 }'

curl -X PUT http://localhost:8098/api/orders/1/confirm
```

Listar pedidos confirmados:

```bash
curl http://localhost:8098/api/orders/status/CONFIRMED
```

## Estructura del Proyecto

```text
.
├── .github/
│   ├── actions/eks-access/   # Acción compuesta: credenciales Learner Lab, herramientas y kubectl
│   ├── dependabot.yml        # Actualizaciones automáticas de dependencias
│   └── workflows/
│       ├── ci-cd.yml         # Pipeline principal (pruebas, seguridad, políticas, build, deploy, métricas)
│       ├── deploy.yml        # Despliegue reutilizable en entorno simulado (Docker Compose)
│       ├── deploy-eks.yml    # Despliegue reutilizable en EKS con verificación y rollback
│       └── failure-demo.yml  # Demostración de bloqueo ante fallas críticas
├── docs/fases/               # Bitácora del desarrollo, fase por fase
├── infra/                    # EKS (eksctl + LabRole), Istio, complementos, limpieza y versiones
├── k8s/                      # Manifiestos de Kubernetes (Kustomize)
│   └── istio/                # Gateway, VirtualService, DestinationRule, mTLS, autorización, Sidecar, Telemetry
├── nginx/nginx.conf          # Configuración del API Gateway
├── observability/            # Reglas de Prometheus, Pushgateway, dashboard Grafana, Kiali y CloudWatch
├── policy/k8s/               # Políticas OPA/Rego evaluadas con conftest
├── scripts/                  # Despliegue, verificación, SLO, métricas CI/CD, auditoría y utilidades
├── src/                      # Código fuente y pruebas
├── Dockerfile                # Build multi-etapa
├── docker-compose.yml        # Orquestación local y de los entornos simulados
├── .env.example              # Plantilla de variables de entorno
├── .trivyignore.yaml         # Excepciones temporales de CVEs
└── pom.xml                   # Dependencias, JaCoCo y SonarCloud
```

El detalle de cada etapa del desarrollo está documentado en `docs/fases`, desde la fundación del proyecto hasta la documentación final.

## Arquitectura y Contenerización

Para garantizar que la aplicación se ejecute de manera idéntica en cualquier entorno, se empaqueta utilizando Docker. El `Dockerfile` está diseñado bajo un enfoque de **construcción multi-etapa (multi-stage build)** que consta de 3 fases: compilación del código fuente con Maven, extracción de las capas de la aplicación y la creación de la imagen final.

**Características de la imagen:**

- **Base ultraligera:** Se utiliza `eclipse-temurin:25-jre-alpine`, que provee un entorno Java (JRE) sobre Alpine Linux, reduciendo drásticamente el peso de la imagen y la superficie de ataque.
- **Seguridad:** El contenedor se ejecuta mediante un usuario sin privilegios llamado `appuser`, evitando el uso de `root`.
- **Monitoreo:** Integra un `HEALTHCHECK` que consulta periódicamente el endpoint `/actuator/health/liveness` para verificar la salud del servicio.
- **Trazabilidad:** Cada imagen es etiquetada de forma automática con el hash del commit (`org.opencontainers.image.revision`).
- **Optimización:** El uso de `.dockerignore` asegura que archivos de desarrollo locales o cachés no se filtren a la imagen final.

## Pipeline CI/CD

El flujo de integración y despliegue continuo está orquestado con **GitHub Actions** y se divide en cuatro workflows:

- `ci-cd.yml`: pipeline principal. Se dispara ante cada `push` a la rama `main` (excepto cuando solo cambian archivos de documentación), al abrir un `pull request` hacia `main` o mediante ejecución manual.
- `deploy.yml`: workflow reutilizable de staging en un entorno simulado con Docker Compose en el runner.
- `deploy-eks.yml`: workflow reutilizable de producción en Amazon EKS con Istio. Despliega, verifica la malla, ejecuta las pruebas de humo y el gate de SLO, y hace rollback automático si algo falla.
- `failure-demo.yml`: ejecución manual que inyecta una falla crítica y demuestra que el pipeline se detiene antes del despliegue.

Las etapas de verificación corren en paralelo, y la construcción de la imagen solo comienza cuando todas terminan con éxito:

1. **Pruebas:** tests unitarios y de integración, con cobertura mínima de 80 % (JaCoCo).
2. **SAST (SonarCloud):** análisis estático con Quality Gate bloqueante.
3. **SCA (Trivy):** dependencias, secretos y configuración del repositorio.
4. **Validación K8s y políticas:** renderizado con la imagen del commit, `kubeconform` con los esquemas de los CRD de Istio, políticas OPA con `conftest` e `istioctl analyze`.
5. **Auditoría de cumplimiento:** controles del repositorio y de la protección de la rama `main`.
6. **Construcción:** empaquetado, escaneo de la imagen y publicación en GitHub Container Registry.
7. **Deploy Staging:** entorno simulado con Docker Compose y pruebas de humo.
8. **Deploy Producción (EKS + Istio):** despliegue en el clúster, verificación post-despliegue y rollback automático.
9. **Métricas del pipeline:** publicación de cobertura, pruebas, vulnerabilidades, resultado y tiempo de despliegue en Prometheus.
10. **Alertas de Seguridad:** issue automático si falla un control de seguridad, de políticas o de cumplimiento.

**Diferencias entre push y pull request:**

|Etapa|Push a `main`|Pull request|
|---|---|---|
|Pruebas, SAST, SCA, políticas K8s y auditoría|Sí|Sí|
|Revisión de dependencias (_dependency review_)|No|Sí|
|Build y escaneo de imagen|Sí|Sí|
|Publicación de imagen en el registro|Sí|No|
|Deploy staging y producción en EKS|Sí|No|
|Métricas del pipeline en Prometheus|Sí|No|
|Issue automático de seguridad|Sí|No|

## Pruebas y Calidad de Código

El proyecto hace un fuerte énfasis en la calidad y fiabilidad de cada entrega. El pipeline ejecuta de manera automatizada **55 pruebas** (unitarias, de controlador e integración) construidas con JUnit.

- **Cobertura:** A través de JaCoCo (configurado en el `pom.xml`), el sistema exige un mínimo del 80% de cobertura. Si este umbral no se alcanza, el pipeline se bloquea. Al cierre de esta entrega, la cobertura era del **94.6%**, con 0 pruebas fallidas; el valor actualizado puede consultarse en el último análisis de SonarCloud.
- **Pruebas de Humo (Smoke Tests):** Una vez desplegada la aplicación, el script `scripts/smoke-test.sh` se ejecuta contra el entorno en vivo para confirmar que la API responde a tráfico real. Todos los reportes de calidad se almacenan como _artifacts_ en las ejecuciones de GitHub Actions.

## Seguridad y Escalabilidad

**Políticas de Seguridad:**

- **Dependabot:** Ejecuta revisiones programadas (cada lunes) para mantener actualizadas las dependencias de Maven, Docker y GitHub Actions.
- **Análisis de Vulnerabilidades:** Trivy detiene inmediatamente el pipeline si detecta vulnerabilidades de nivel `HIGH` o `CRITICAL`. Se cuenta con un archivo `.trivyignore.yaml` que excluye temporalmente (hasta el 2027-01-31) 2 CVEs específicos que no aplican al contexto de esta aplicación.
- **Hardening de Contenedores:** Los contenedores corren en modo `read_only`, pierden capacidades innecesarias de sistema (`cap_drop ALL`), utilizan redes internas aisladas y se les asigna una contraseña de base de datos aleatoria por despliegue.
- **Bloqueos Automáticos:** Si SAST o SCA fallan, se genera un _Issue_ automático con la etiqueta `security-gate`. (Por ejemplo, el [Issue #4](https://github.com/zzykos/zzykos-order-manager/issues/4) que reportaba la ausencia del `SONAR_TOKEN`, resuelto al inyectar el secreto en la configuración del repositorio).

**Estrategia de Escalabilidad:**

- La arquitectura soporta múltiples réplicas (1 en staging, 2 en producción) balanceadas a través de un API Gateway configurado con **Nginx**.
- Se implementaron límites estrictos de CPU y memoria por servicio en `docker-compose.yml`.
- Para despliegues nativos de nube, los manifiestos de Kubernetes incluyen políticas de Autoescalado Horizontal (HPA), configuradas para variar dinámicamente entre 2 y 6 réplicas según el consumo de recursos.

## Trazabilidad y Despliegue

Se implementó un entorno _cloud simulado_ utilizando Docker Compose corriendo directamente en los _runners_ de GitHub Actions. En la sección de [_Deployments_](https://github.com/zzykos/zzykos-order-manager/deployments) del repositorio se puede observar el estado de los dos entornos principales: **staging** y **produccion-simulada**.

**Cadena de Trazabilidad Total:**

1. Todo cambio se origina en un **Commit**.
2. GitHub Actions captura el **SHA** de ese commit.
3. La imagen Docker se etiqueta con ese **SHA**.
4. En tiempo de ejecución, consultar el endpoint `/actuator/info` expone públicamente la información del commit, permitiendo saber en todo momento qué versión exacta del código está corriendo en cada entorno.

Ejemplo de respuesta:

```bash
curl http://localhost:8098/actuator/info
```

```json
{
  "app": {
    "version": "1.0.0",
    "commit": "<sha-del-commit-desplegado>"
  }
}
```

El smoke test compara este valor con el commit esperado, por lo que un despliegue que no corresponda al commit del pipeline falla automáticamente.

## Orquestación

La infraestructura de servicios está definida en `docker-compose.yml` e integra 3 componentes principales:

- **db:** Base de datos PostgreSQL 17.
- **app:** Instancias del microservicio Order Manager.
- **gateway:** Proxy reverso Nginx.

Estos servicios cuentan con _healthchecks_ internos y directivas `depends_on` para asegurar el orden correcto de arranque y reinicios automáticos en caso de fallos.

### Kubernetes

Adicionalmente, el directorio `/k8s` contiene los manifiestos, organizados con Kustomize, listos para migrar a un clúster de Kubernetes real: Namespace, ConfigMap, StatefulSet de PostgreSQL, Deployment y Service de la aplicación, HPA, PodDisruptionBudget y NetworkPolicies.

**Requisitos del clúster:** Kubernetes 1.32 a 1.36 (compatibles con Istio 1.31), [metrics-server](https://github.com/kubernetes-sigs/metrics-server) para el HPA e Istio instalado con `infra/istio/install.sh`. Los manifiestos incluyen el namespace con inyección del sidecar y los recursos de la malla en `k8s/istio`. Para el despliegue completo en EKS ver [Service Mesh en Amazon EKS](#service-mesh-en-amazon-eks-istio-y-kiali).

```bash
# 1. Crear el namespace y el secreto con la contraseña de la base de datos
kubectl create namespace order-manager
kubectl -n order-manager create secret generic order-manager-db \
  --from-literal=DB_PASSWORD='cambiar-esta-clave'

# 2. Aplicar todos los manifiestos
kubectl apply -k k8s/

# 3. Verificar el estado
kubectl -n order-manager get pods,svc,hpa

# 4. Acceder a la API desde la máquina local
kubectl -n order-manager port-forward svc/order-manager 8098:80
```

## Service Mesh en Amazon EKS (Istio y Kiali)

El entorno productivo corre en Amazon EKS (`cluster-istio`, `us-east-1`) dentro de una malla Istio 1.31.4. El clúster se crea con `eksctl` usando el rol `LabRole` de AWS Academy Learner Lab para el plano de control y para los nodos (3 x `t3.medium`), sin roles IAM nuevos ni proveedor OIDC. El detalle de la arquitectura y de las decisiones de diseño está en [`docs/fases/fase-11-observabilidad.md`](docs/fases/fase-11-observabilidad.md).

|Recurso|Función|
|---|---|
|`Gateway` + `VirtualService`|Entrada por el ingress gateway; expone solo `/api/orders`, `/actuator/health` y `/actuator/info`, con timeouts y reintentos ante fallas de conexión|
|`DestinationRule`|mTLS hacia los destinos, balanceo `LEAST_REQUEST`, límites de conexiones y *outlier detection* (circuit breaker)|
|`PeerAuthentication`|mTLS `STRICT` en todo el namespace|
|`AuthorizationPolicy`|Denegación por defecto; solo el ingress gateway llama a la API y solo `order-manager` llega a PostgreSQL|
|`Sidecar`|Salida restringida al registro de la malla (`REGISTRY_ONLY`)|
|`Telemetry`|Access logs de Envoy y trazas hacia Jaeger|

```bash
./scripts/install-tools.sh istioctl kustomize conftest eksctl
./infra/eks/create-cluster.sh
./infra/istio/install.sh
./infra/addons/install.sh
ALERT_EMAIL=equipo@example.com ./observability/cloudwatch/setup.sh
./scripts/port-forward.sh
```

Las consolas se abren por defecto con `port-forward`: Kiali en `http://127.0.0.1:20001`, Grafana en `:3000`, Prometheus en `:9090`, Jaeger en `:16686` y la API en `:8080`. Como alternativa opcional, `EXPOSE_KIALI_LB=true ./infra/addons/install.sh` aplica `observability/kiali/kiali-lb.yaml` y publica Kiali con un balanceador de AWS en el puerto 20001. Debe eliminarse al terminar, porque deja la consola accesible desde internet. `./infra/cleanup.sh` libera todos los recursos en el orden correcto.

## Monitoreo, Métricas y Dashboards

|Herramienta|Qué observamos|
|---|---|
|Prometheus|Métricas de Envoy (RPS, códigos, latencia), de la JVM y HTTP (Micrometer en `/actuator/prometheus`), de CPU y memoria (cAdvisor) y del pipeline (Pushgateway)|
|Grafana|Dashboard **Order Manager - DevOps**, versionado en `observability/grafana/dashboards` y sincronizado en cada despliegue|
|Kiali|Grafo de tráfico en vivo, estado de mTLS y validación de los recursos de Istio|
|Jaeger|Trazas distribuidas gateway → `order-manager` → `postgres`|
|CloudWatch|Container Insights, logs centralizados (aplicación en JSON ECS y access logs de Envoy), filtro de métricas de errores, dashboard y alarmas con notificación SNS por correo|

El dashboard une las dos caras del sistema:

- **CI/CD:** resultado del pipeline, cobertura de pruebas, tiempo de despliegue y su tendencia, pruebas ejecutadas y fallidas, vulnerabilidades de la imagen, y trazabilidad commit → imagen → ejecución.
- **Ejecución:** disponibilidad frente al SLO de 99 %, RPS, latencia p50/p95/p99, errores 5xx, errores registrados en logs, uso de CPU y memoria por contenedor, heap de la JVM y proporción de tráfico mTLS.

Las reglas de grabación y las alertas están en `observability/prometheus/rules-patch.yaml`; las alarmas de CloudWatch, en `observability/cloudwatch/setup.sh`. La tabla de qué decisión técnica se toma ante cada señal está en la [fase 11](docs/fases/fase-11-observabilidad.md#cómo-estas-señales-guían-nuestras-decisiones-técnicas).

## Políticas de Cumplimiento y Auditoría

- **Calidad:** JaCoCo (mínimo 80 %) y Quality Gate de SonarQube bloqueante.
- **Seguridad de la cadena de suministro:** Trivy (código, dependencias, secretos e imagen), Dependency Review en los PR, acciones fijadas por SHA y Dependabot.
- **Políticas como código:** `policy/k8s/*.rego`, evaluadas con `conftest` sobre los manifiestos renderizados: hardening de contenedores, identidades dedicadas, imágenes inmutables, sondas, mTLS STRICT, denegación por defecto, egress restringido, HPA y PDB.
- **Auditoría automatizada:** `scripts/compliance-audit.sh` genera `compliance-report.json` en cada ejecución (artefacto con retención de 90 días).
- **Protección de rama:** `scripts/branch-protection.sh` define el ruleset de `main`: PR con aprobación, checks obligatorios, historial lineal y sin force push. La auditoría verifica que siga activo.

El detalle de cada control está en [`docs/fases/fase-12-cumplimiento.md`](docs/fases/fase-12-cumplimiento.md).

## Detención Automática del Pipeline

Cada control bloqueante termina con código distinto de cero. GitHub Actions no ejecuta los jobs que dependen de él, así que la imagen no se publica y no se despliega. Después del despliegue en EKS, `scripts/post-deploy-verify.sh` valida la malla, ejecuta las pruebas de humo y evalúa los SLO de la revisión nueva con métricas de Istio (errores 5xx <= 1 %, p95 <= 1 s). Si no se cumplen, `scripts/rollback-eks.sh` restaura la revisión anterior y la ejecución queda marcada como fallida.

Para demostrarlo, ejecutamos **Actions → Demostración de bloqueo del pipeline** con uno de los escenarios `cobertura-insuficiente`, `dependencia-vulnerable`, `manifiesto-inseguro` o `mtls-desactivado`. El resumen de la ejecución muestra el control fallido y el despliegue en estado `skipped`.

## Configuración del Repositorio y del Clúster

|Tipo|Nombre|Valor|
|---|---|---|
|Secret|`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`|Credenciales de *AWS Details* del Learner Lab. Expiran con cada sesión y deben renovarse antes de ejecutar el pipeline|
|Secret|`SONAR_TOKEN`|Token de SonarQube Cloud|
|Variable|`AWS_REGION`|`us-east-1` (opcional)|
|Variable|`EKS_CLUSTER`|`cluster-istio` (opcional)|
|Environment|`produccion-eks`|Puede exigir aprobación manual antes del despliegue|
|Paquete GHCR|`zzykos-order-manager`|Visibilidad pública, para que los nodos de EKS descarguen la imagen sin credenciales|

Pasos iniciales:

1. Cargar los secrets y crear el clúster con la secuencia de la sección [Service Mesh](#service-mesh-en-amazon-eks-istio-y-kiali).
2. Ejecutar `GH_TOKEN=<token-admin> ./scripts/branch-protection.sh zzykos/zzykos-order-manager` para activar la protección de `main` que exige la auditoría.
3. Integrar en `main` mediante pull request. El pipeline despliega en EKS y publica las métricas del pipeline en Grafana.

## Evidencias del Proyecto

- **Pipeline exitoso:** [Ejecución #40329926042 en Actions](https://github.com/zzykos/zzykos-order-manager/actions/runs/40329926042)
- **Bloqueo por seguridad resuelto:** [Issue #4](https://github.com/zzykos/zzykos-order-manager/issues/4)
- **Imágenes Docker:** [Paquete en GitHub Container Registry](https://github.com/zzykos/zzykos-order-manager/pkgs/container/zzykos-order-manager)
- **Deployments:** [Historial de despliegues](https://github.com/zzykos/zzykos-order-manager/deployments) por entorno (staging / produccion-simulada).

## Declaración de uso de IA

Para el desarrollo de este proyecto, se utilizó el modelo Claude Opus 5.5 exclusivamente como herramienta de apoyo para verificar el funcionamiento del código y corregir errores puntuales de sintaxis y ejecución. Toda la configuración de infraestructura, diseño del pipeline y redacción de esta documentación fue realizada de manera manual y sin intervención automatizada. _Cita: Anthropic. (2026). Claude Opus 5.5 [Modelo de lenguaje de gran tamaño]. [https://claude.ai](https://claude.ai)_

## Conclusiones y Reflexión Individual

### Aprendizajes

A lo largo del desarrollo de este proyecto, he aprendido el funcionamiento correcto de las metodologías CI/CD y la automatización de despliegues. Durante este proceso, comprendí la cantidad de veces que un pipeline puede fallar, asimilando que cada error es un avance en el aprendizaje y no un retroceso.

### Dificultades

En cuanto a las dificultades técnicas, el mayor desafío fue configurar correctamente los volúmenes de Docker, ya que tuve muchos problemas para que el sistema los leyera de forma adecuada. Para solucionar este inconveniente, dediqué tiempo a revisar múltiples videos explicativos y consulté de manera específica a Claude Opus 5.5, lo que me permitió comprender la configuración necesaria.

### Mejoras futuras

En el futuro, me gustaría agregar herramientas de monitoreo adicionales para tener mayor visibilidad de la infraestructura y optimizar aún más el código del servicio.

---

Proyecto académico desarrollado para la asignatura DOY0101 Ingeniería DevOps, a partir del [repositorio base](https://github.com/iam-docente/order-manager) entregado por el docente.