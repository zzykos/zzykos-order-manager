# Fase 12: Políticas de cumplimiento y auditoría automatizada en CI/CD

En esta fase convertimos los requisitos de seguridad y calidad en controles automáticos que se ejecutan en cada cambio. Si un control falla, el pipeline se detiene antes de publicar la imagen o de desplegar en EKS. Si la falla aparece después del despliegue, la versión anterior se restaura automáticamente.

## Controles por etapa

| Etapa | Control | Herramienta | Condición que detiene el pipeline |
|---|---|---|---|
| Pruebas | Pruebas unitarias, de controlador y de integración; cobertura | JUnit y JaCoCo | Cualquier prueba fallida o cobertura de líneas < 80 % |
| SAST | Calidad y seguridad del código | SonarQube Cloud (`sonar.qualitygate.wait=true`) | Quality Gate en estado *Failed*, o falta de `SONAR_TOKEN` en `main` |
| SCA | Dependencias, secretos y configuración del repositorio | Trivy fs, Dependency Review | Vulnerabilidad HIGH/CRITICAL corregible, secreto expuesto o mala configuración |
| Políticas K8s | Esquema de Kubernetes y de los CRD de Istio | kubeconform | Recurso inválido |
| Políticas K8s | Seguridad de workloads y de la malla | conftest (OPA/Rego) en `policy/k8s` | Ver tabla de políticas |
| Políticas K8s | Semántica de Istio | `istioctl analyze` | Error de configuración de la malla |
| Cumplimiento | Auditoría del repositorio | `scripts/compliance-audit.sh` | Cualquier control con estado FAIL |
| Imagen | Vulnerabilidades de la imagen final | Trivy image | HIGH/CRITICAL corregible |
| Despliegue EKS | Malla, pruebas de humo y SLO | `scripts/post-deploy-verify.sh` | Pod sin sidecar, mTLS no estricto, tráfico en texto plano aceptado, smoke test fallido, errores 5xx > 1 % o p95 > 1 s |
| Despliegue EKS | Protección del entorno productivo | `scripts/rollback-eks.sh` | Ante una verificación fallida restauramos la revisión anterior y marcamos la ejecución como fallida |

## Políticas como código (`policy/k8s`)

| Paquete | Política |
|---|---|
| `workload` | Contenedores con `requests` y `limits` de CPU y memoria |
| `workload` | Sin contenedores privilegiados, `allowPrivilegeEscalation=false`, `readOnlyRootFilesystem=true`, `drop: [ALL]` |
| `workload` | Ejecución como no root y perfil `seccomp` declarado |
| `workload` | Sin `hostNetwork`, `hostPID` ni `hostIPC` |
| `workload` | ServiceAccount dedicada y sin montaje automático de token |
| `workload` | Sondas `readinessProbe` y `livenessProbe` en Deployments y StatefulSets |
| `workload` | Imágenes con etiqueta inmutable o digest (no `latest`) |
| `workload` | Prohibido desactivar la inyección del sidecar de Istio |
| `network` | Namespace con `istio-injection=enabled` y Pod Security `restricted` |
| `network` | Servicios de la aplicación sin `LoadBalancer` ni `NodePort` (la entrada pasa por el ingress gateway) |
| `network` | `PeerAuthentication` en `STRICT` también a nivel de puerto, y `DestinationRule` sin TLS desactivado |
| `network` | Toda regla `ALLOW` de `AuthorizationPolicy` restringe el origen |
| `network` | Puertos de Service con protocolo declarado para Istio |
| `mesh` (combinado) | Existen la `PeerAuthentication` STRICT del namespace, la política `allow-nothing`, un `Sidecar` con `REGISTRY_ONLY` y un `Telemetry` con logs y trazas |
| `mesh` (combinado) | Cada Deployment tiene una `AuthorizationPolicy` ALLOW, un HPA y un PodDisruptionBudget |

Las políticas se evalúan sobre los manifiestos renderizados con la imagen exacta del commit. Así validamos lo mismo que después se aplica en el clúster.

## Seguridad de la malla (zero trust)

- `PeerAuthentication default` en modo `STRICT`: solo se acepta tráfico mTLS entre workloads de la malla.
- `AuthorizationPolicy allow-nothing`: todo se deniega por defecto en el namespace.
- `order-manager-from-ingress`: solo la identidad del ingress gateway puede invocar `/api/orders` y los endpoints públicos de Actuator.
- `order-manager-deny-sensitive-actuator`: deniega en el propio sidecar cualquier endpoint de Actuator distinto de `health` e `info`.
- `postgres-from-order-manager`: solo la ServiceAccount `order-manager` puede abrir conexiones al puerto 5432.
- `Sidecar default` con `REGISTRY_ONLY`: los pods no pueden salir a destinos fuera del registro de la malla.
- NetworkPolicies (con la aplicación de políticas activada en VPC CNI) como segunda capa en L3/L4.

`scripts/verify-mesh.sh` comprueba estas garantías en el clúster en cada despliegue. Incluye una prueba activa: desde un namespace fuera de la malla intentamos llamar a la API en texto plano y verificamos que la conexión se rechaza.

## Auditoría del repositorio (`scripts/compliance-audit.sh`)

| Control | Verificación |
|---|---|
| CI-01 | Toda acción de terceros en los workflows está fijada por SHA de 40 caracteres |
| CI-02 | Todo workflow declara `permissions` explícitos |
| CI-03 | El Quality Gate de SonarQube es bloqueante |
| CI-04 | El umbral de cobertura de JaCoCo es de al menos 0.80 |
| SC-01 | La imagen corre con un usuario no root y tiene `HEALTHCHECK` |
| SC-02 | Las imágenes base no usan `latest` ni carecen de etiqueta |
| SC-03 | Cada excepción de Trivy tiene justificación y fecha de expiración vigente |
| SC-04 | No hay `.env`, llaves privadas ni certificados versionados |
| SC-05 | Dependabot está configurado |
| GH-01 | La rama `main` tiene reglas activas: pull request, checks obligatorios, sin force push y sin eliminación |

El resultado queda en `compliance-report.json`, que se publica como artefacto con retención de 90 días. Eso nos deja un registro de auditoría por commit.

## Protección de la rama `main`

`scripts/branch-protection.sh OWNER/REPO` crea el ruleset `proteccion-main`:

- cambios solo por pull request, con 1 aprobación, aprobaciones invalidadas ante nuevos commits, aprobación del último push y conversaciones resueltas;
- checks obligatorios: pruebas, SAST, SCA, políticas de Kubernetes, auditoría de cumplimiento e imagen Docker, con la rama actualizada respecto de `main`;
- historial lineal, sin force push y sin eliminación de la rama.

Lo ejecutamos una vez con un token de administración del repositorio. La auditoría GH-01 verifica en cada pipeline que el ruleset siga vigente.

## Demostración de detención del pipeline

El workflow manual **Demostración de bloqueo del pipeline** (`failure-demo.yml`) inyecta una falla crítica en una copia efímera del código y comprueba que la etapa de despliegue nunca llega a ejecutarse:

| Escenario | Falla inyectada | Control que la detiene |
|---|---|---|
| `cobertura-insuficiente` | Umbral de cobertura exigido de 99 % | JaCoCo (`mvn verify`) |
| `dependencia-vulnerable` | `log4j-core 2.14.1` (CVE-2021-44228, CRITICAL) | Trivy |
| `manifiesto-inseguro` | Contenedor privilegiado con escalamiento de privilegios | conftest (`workload`) |
| `mtls-desactivado` | `PeerAuthentication` en `PERMISSIVE` | conftest (`network` y `mesh`) |

La etapa final del workflow solo termina con éxito si el control falló y el despliegue quedó en estado `skipped`. Si un control dejara de ser efectivo, la demostración misma falla.

En el pipeline real hay una protección adicional después del despliegue: si la revisión nueva no cumple los SLO, `rollback-eks.sh` restaura la versión anterior. Prometheus registra `cicd_deploy_rolled_back=1` y la alerta `CicdDeploymentRolledBack` queda activa en Grafana.
