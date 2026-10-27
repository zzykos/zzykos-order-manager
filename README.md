# Order Manager

> **Asignatura:** DOY0101 Ingeniería DevOps **Estudiante:** Jairo Omar Moraga Rodriguez **Repositorio Base:** [https://github.com/iam-docente/order-manager](https://github.com/iam-docente/order-manager)

Order Manager es un microservicio diseñado para la gestión de pedidos, construido como una API REST utilizando Spring Boot 3.5 y Java 17.

Este repositorio implementa toda la infraestructura DevOps necesaria para el ciclo de vida de la aplicación: contenerización optimizada, un pipeline de integración y entrega continua (CI/CD), políticas de seguridad estrictas y orquestación para su despliegue.

## Índice

- [Ejecución Local](#ejecuci%C3%B3n-local)
- [API REST](#api-rest)
- [Estructura del Proyecto](#estructura-del-proyecto)
- [Arquitectura y Contenerización](#arquitectura-y-contenerizaci%C3%B3n)
- [Pipeline CI/CD](#pipeline-cicd)
- [Pruebas](#pruebas)
- [Seguridad y Escalabilidad](#seguridad-y-escalabilidad)
- [Trazabilidad y Despliegue](#trazabilidad-y-despliegue)
- [Orquestación](#orquestaci%C3%B3n)
- [Evidencias del Proyecto](#evidencias-del-proyecto)
- [Declaración de uso de IA](#declaraci%C3%B3n-de-uso-de-ia)
- [Conclusión y Reflexión](#conclusiones-y-reflexi%C3%B3n-individual)

## Ejecución Local

### Requisitos

|Herramienta|Versión|
|---|---|
|Java (JDK)|17|
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
│   ├── dependabot.yml        # Actualizaciones automáticas de dependencias
│   └── workflows/
│       ├── ci-cd.yml         # Pipeline principal (pruebas, seguridad, build, deploy)
│       └── deploy.yml        # Workflow reutilizable de despliegue por entorno
├── docs/fases/               # Bitácora del desarrollo, fase por fase
├── k8s/                      # Manifiestos de Kubernetes (Kustomize)
├── nginx/nginx.conf          # Configuración del API Gateway
├── scripts/smoke-test.sh     # Pruebas de humo post-despliegue
├── src/                      # Código fuente y pruebas
├── Dockerfile                # Build multi-etapa
├── docker-compose.yml        # Orquestación local y de los entornos simulados
├── .env.example              # Plantilla de variables de entorno
├── .trivyignore.yaml         # Excepciones temporales de CVEs
└── pom.xml                   # Dependencias, JaCoCo y SonarCloud
```


## Arquitectura y Contenerización

Para garantizar que la aplicación se ejecute de manera idéntica en cualquier entorno, se empaqueta utilizando Docker. El `Dockerfile` está diseñado bajo un enfoque de **construcción multi-etapa (multi-stage build)** que consta de 3 fases: compilación del código fuente con Maven, extracción de las capas de la aplicación y la creación de la imagen final.

**Características de la imagen:**

- **Base ultraligera:** Se utiliza `eclipse-temurin:17-jre-alpine`, que provee un entorno Java (JRE) sobre Alpine Linux, reduciendo drásticamente el peso de la imagen y la superficie de ataque.
- **Seguridad:** El contenedor se ejecuta mediante un usuario sin privilegios llamado `appuser`, evitando el uso de `root`.
- **Monitoreo:** Integra un `HEALTHCHECK` que consulta periódicamente el endpoint `/actuator/health/liveness` para verificar la salud del servicio.
- **Trazabilidad:** Cada imagen es etiquetada de forma automática con el hash del commit (`org.opencontainers.image.revision`).
- **Optimización:** El uso de `.dockerignore` asegura que archivos de desarrollo locales o cachés no se filtren a la imagen final.

## Pipeline CI/CD

El flujo de integración y despliegue continuo está orquestado con **GitHub Actions** y se divide en dos workflows:

- `ci-cd.yml`: pipeline principal. Se dispara ante cada `push` a la rama `main` (excepto cuando solo cambian archivos de documentación), al abrir un `pull request` hacia `main` o mediante ejecución manual.
- `deploy.yml`: workflow reutilizable que no se ejecuta por sí solo; `ci-cd.yml` lo invoca una vez por entorno (staging y producción simulada) con la imagen y la cantidad de réplicas correspondientes.

Las etapas de verificación (pruebas, SAST, SCA y validación de Kubernetes) corren en paralelo, y la construcción de la imagen solo comienza cuando todas terminan con éxito:

1. **Pruebas:** Verificación del código mediante tests unitarios y de integración.
2. **SAST (SonarCloud):** Análisis estático en busca de _code smells_ o vulnerabilidades.
3. **SCA (Trivy):** Escaneo de dependencias y vulnerabilidades en la imagen Docker.
4. **Validación K8s:** Renderizado de los manifiestos con Kustomize y validación contra el esquema de Kubernetes con `kubeconform`.
5. **Construcción:** Empaquetado, escaneo y publicación de la imagen Docker en GitHub Container Registry.
6. **Deploy Staging:** Despliegue automático en el entorno de staging, simulado con Docker Compose en el runner de GitHub Actions.
7. **Deploy Producción (Simulada):** Pase al entorno productivo, solo si staging fue exitoso.
8. **Alertas de Seguridad:** Generación de notificaciones si algún paso crítico falla.

**Diferencias entre push y pull request:**

|Etapa|Push a `main`|Pull request|
|---|---|---|
|Pruebas, SAST, SCA y validación K8s|Sí|Sí|
|Revisión de dependencias (_dependency review_)|No|Sí|
|Build y escaneo de imagen|Sí|Sí|
|Publicación de imagen en el registro|Sí|No|
|Deploy staging y producción simulada|Sí|No|
|Issue automático de seguridad|Sí|No|

## Pruebas

El pipeline ejecuta de manera automatizada **55 pruebas** (unitarias, de controlador e integración) construidas con JUnit.

- **Cobertura:** A través de JaCoCo (configurado en el `pom.xml`), el sistema exige un mínimo del 80% de cobertura. Si este porcentaje no se alcanza, el pipeline se bloquea. Al cierre de esta entrega, la cobertura era del **94.6%**, con 0 pruebas fallidas; el valor actualizado puede consultarse en el último análisis de SonarCloud.
- **Pruebas de Humo (Smoke Tests):** Una vez desplegada la aplicación, el script `scripts/smoke-test.sh` se ejecuta contra el entorno en vivo para confirmar que la API responde a tráfico real. Todos los reportes de calidad se almacenan como _artifacts_ en las ejecuciones de GitHub Actions.

## Seguridad y Escalabilidad

**Políticas de Seguridad:**

- **Dependabot:** Ejecuta revisiones programadas (cada lunes) para mantener actualizadas las dependencias de Maven, Docker y GitHub Actions.
- **Hardening de Contenedores:** Los contenedores corren en modo `read_only`, pierden capacidades innecesarias de sistema (`cap_drop ALL`), utilizan redes internas aisladas y se les asigna una contraseña de base de datos aleatoria por despliegue.
- **Bloqueos Automáticos:** Si SAST o SCA fallan, se genera un _Issue_ automático con la etiqueta `security-gate`.

**Estrategia de Escalabilidad:**

- La arquitectura soporta múltiples réplicas (1 en staging, 2 en producción) balanceadas a través de un API Gateway configurado con **Nginx**.
- Se implementaron límites de CPU y memoria por servicio en `docker-compose.yml`.


## Trazabilidad y Despliegue

Se implementó un entorno _cloud simulado_ utilizando Docker Compose corriendo directamente en los _runners_ de GitHub Actions. En la sección de [_Deployments_](https://github.com/zzykos/zzykos-order-manager/deployments) del repositorio se puede observar el estado de los dos entornos principales: **staging** y **produccion-simulada**.

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

### Kubernetes

**Requisitos del clúster:** Kubernetes 1.30 o superior y [metrics-server](https://github.com/kubernetes-sigs/metrics-server) instalado, necesario para que el HPA pueda escalar según el consumo.

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
