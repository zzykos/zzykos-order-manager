> **Asignatura:** DOY0101 Ingeniería DevOps **Autor:** (tu nombre) **Repositorio Base:** https://github.com/iam-docente/order-manager

Order Manager es un microservicio diseñado para la gestión de pedidos, construido como una API REST utilizando Spring Boot 3.5 y Java 17.

Este repositorio contiene no solo el código fuente de la aplicación (desarrollado inicialmente en fases previas), sino que implementa toda la infraestructura DevOps necesaria para su ciclo de vida: contenerización optimizada, un pipeline de integración y entrega continua (CI/CD), políticas de seguridad estrictas y orquestación para su despliegue.

## Arquitectura y Contenerización

Para garantizar que la aplicación se ejecute de manera idéntica en cualquier entorno, la empaquetamos utilizando Docker. El `Dockerfile` está diseñado bajo un enfoque de **construcción multi-etapa (multi-stage build)** que consta de 3 fases: compilación del código fuente con Maven, extracción de las capas de la aplicación y la creación de la imagen final.

**Características de la imagen:**

- **Base ultraligera:** Utilizamos `eclipse-temurin:17-jre-alpine`, que provee un entorno Java (JRE) sobre Alpine Linux, reduciendo drásticamente el peso de la imagen y la superficie de ataque.
    
- **Seguridad:** El contenedor se ejecuta mediante un usuario sin privilegios llamado `appuser`, evitando el uso de `root`.
    
- **Monitoreo:** Integra un `HEALTHCHECK` que consulta periódicamente el endpoint `/actuator/health/liveness` para verificar la salud del servicio.
    
- **Trazabilidad:** Cada imagen es etiquetada de forma automática con el hash del commit (`org.opencontainers.image.revision`).
    
- **Optimización:** El uso de `.dockerignore` asegura que archivos de desarrollo locales o cachés no se filtren a la imagen final.
    

## Pipeline CI/CD

El flujo de integración y despliegue continuo está orquestado con **GitHub Actions**. Los workflows principales (`ci-cd.yml` y `deploy.yml`) se disparan automáticamente ante cada `push` a la rama `main`, al abrir un `pull request` o mediante ejecución manual.

El pipeline sigue un orden secuencial estricto:

1. **Pruebas:** Verificación del código mediante tests unitarios y de integración.
    
2. **SAST (SonarCloud):** Análisis estático en busca de _code smells_ o vulnerabilidades.
    
3. **SCA (Trivy):** Escaneo de dependencias y vulnerabilidades en la imagen Docker.
    
4. **Validación K8s:** Revisión de sintaxis en los manifiestos de Kubernetes (solo en PRs).
    
5. **Construcción:** Empaquetado y publicación de la imagen Docker.
    
6. **Deploy Staging:** Despliegue automático en el entorno de pruebas local.
    
7. **Deploy Producción (Simulada):** Pase al entorno productivo.
    
8. **Alertas de Seguridad:** Generación de notificaciones si algún paso crítico falla.
    

## Pruebas y Calidad de Código

El proyecto hace un fuerte énfasis en la calidad y fiabilidad de cada entrega. El pipeline ejecuta de manera automatizada **55 pruebas** (unitarias, de controlador e integración) construidas con JUnit.

- **Cobertura:** A través de JaCoCo (configurado en el `pom.xml`), el sistema exige un mínimo del 80% de cobertura. Si este umbral no se alcanza, el pipeline se bloquea. Actualmente, la cobertura real es del **94.6%**, con 0 pruebas fallidas.
    
- **Pruebas de Humo (Smoke Tests):** Una vez desplegada la aplicación, el script `scripts/smoke-test.sh` se ejecuta contra el entorno en vivo para confirmar que la API responde a tráfico real. Todos los reportes de calidad se almacenan como _artifacts_ en las ejecuciones de GitHub Actions.
    

## Seguridad y Escalabilidad

**Políticas de Seguridad:**

- **Dependabot:** Ejecuta revisiones programadas (cada lunes) para mantener actualizadas las dependencias de Maven, Docker y GitHub Actions.
    
- **Análisis de Vulnerabilidades:** Trivy detiene inmediatamente el pipeline si detecta vulnerabilidades de nivel `HIGH` o `CRITICAL`. Contamos con un archivo `.trivyignore.yaml` que excluye temporalmente (hasta el 2027-01-31) 2 CVEs específicos que no aplican al contexto de esta aplicación.
    
- **Hardening de Contenedores:** Los contenedores corren en modo `read_only`, pierden capacidades innecesarias de sistema (`cap_drop ALL`), utilizan redes internas aisladas y se les asigna una contraseña de base de datos aleatoria por despliegue.
    
- **Bloqueos Automáticos:** Si SAST o SCA fallan, se genera un _Issue_ automático con la etiqueta `security-gate`. (Por ejemplo, el Issue #4 que reportaba la ausencia del `SONAR_TOKEN`, resuelto al inyectar el secreto en la configuración del repositorio).
    

**Estrategia de Escalabilidad:**

- La arquitectura soporta múltiples réplicas (1 en staging, 2 en producción) balanceadas a través de un API Gateway configurado con **Nginx**.
    
- Se implementaron límites estrictos de CPU y memoria por servicio en `docker-compose.yml`.
    
- Para despliegues nativos de nube, los manifiestos de Kubernetes incluyen políticas de Autoescalado Horizontal (HPA), configuradas para variar dinámicamente entre 2 y 6 réplicas según el consumo de recursos.
    

## Trazabilidad y Despliegue

Implementamos un entorno _cloud simulado_ utilizando Docker Compose corriendo directamente en los _runners_ de GitHub Actions. En la sección de _Deployments_ del repositorio, puedes observar el estado de nuestros dos entornos principales: **staging** y **produccion-simulada**.

**Cadena de Trazabilidad Total:**

1. Todo cambio se origina en un **Commit**.
    
2. GitHub Actions captura el **SHA** de ese commit.
    
3. La imagen Docker se etiqueta con ese **SHA**.
    
4. En tiempo de ejecución, consultar el endpoint `/actuator/info` expone públicamente la información del commit, permitiendo saber en todo momento qué versión exacta del código está corriendo en cada entorno.
    

## Orquestación

La infraestructura de servicios está definida en `docker-compose.yml` e integra 3 componentes principales:

- **db:** Base de datos PostgreSQL 17.
    
- **app:** Instancias del microservicio Order Manager.
    
- **gateway:** Proxy reverso Nginx.
    

Estos servicios cuentan con _healthchecks_ internos y directivas `depends_on` para asegurar el orden correcto de arranque y reinicios automáticos en caso de fallos. Adicionalmente, el directorio `/k8s` contiene los manifiestos (Deployments, Services, Ingress, HPA) listos para migrar a un clúster de Kubernetes real.

## Ejecución Local

Para levantar el proyecto en tu entorno de desarrollo, asegúrate de tener Maven y Docker instalados, y ejecuta:

```
# 1. Correr las pruebas localmente
mvn test

# 2. Configurar variables de entorno
cp .env.example .env

# 3. Levantar la infraestructura
docker compose up -d

```

## Evidencias del Proyecto

- **Pipeline exitoso:** [Ejecución #40329926042 en Actions](https://github.com/zzykos/zzykos-order-manager/actions/runs/40329926042 "null")
    
- **Bloqueo por seguridad resuelto:** Issue #4
    
- **Imágenes Docker:** Visibles en la pestaña _Packages_ del repositorio.
    
- **Deployments:** Historial de despliegues visible en los _Environments_ (staging / produccion-simulada).
    

## Declaración de uso de IA

Para el desarrollo de este proyecto, se utilizó el modelo Claude Opus 5.5 exclusivamente como herramienta de apoyo para verificar el funcionamiento del código y corregir errores puntuales de sintaxis y ejecución. Toda la configuración de infraestructura, diseño del pipeline y redacción de esta documentación fue realizada de manera manual y sin intervención automatizada. _Cita: Anthropic. (2026). Claude Opus 5.5 [Modelo de lenguaje de gran tamaño]. https://claude.ai_

## Conclusiones y Reflexión Individual

A lo largo del desarrollo de este proyecto, he aprendido el funcionamiento correcto de las metodologías CI/CD y la automatización de despliegues. Durante este proceso, comprendí la cantidad de veces que un pipeline puede fallar, asimilando que cada error es un avance en el aprendizaje y no un retroceso. En cuanto a las dificultades técnicas, el mayor desafío fue configurar correctamente los volúmenes de Docker, ya que tuve muchos problemas para que el sistema los leyera de forma adecuada. Para solucionar este inconveniente, dediqué tiempo a revisar múltiples videos explicativos y consulté de manera específica a Claude Opus 5.5, lo que me permitió comprender la configuración necesaria. En el futuro, me gustaría agregar herramientas de monitoreo adicionales para tener mayor visibilidad de la infraestructura y optimizar aún más el código del servicio.
