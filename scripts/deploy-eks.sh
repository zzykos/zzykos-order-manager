#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: deploy-eks.sh render ARCHIVO_SALIDA
     deploy-eks.sh apply  [ARCHIVO_SALIDA]

render  Genera los manifiestos finales (Kustomize) con la imagen y el commit indicados.
apply   Genera, aplica en el cluster y espera a que el rollout termine.

Variables de entorno:
  IMAGE             Imagen inmutable a desplegar, por ejemplo ghcr.io/org/repo:<sha> (obligatoria)
  GIT_COMMIT        Commit desplegado (obligatoria)
  APP_VERSION       Version de la aplicacion (por defecto 1.0.0-<commit corto>)
  APP_NAMESPACE     Namespace de la aplicacion (por defecto infra/versions.env)
  ROLLOUT_TIMEOUT   Tiempo maximo de rollout (por defecto 300s)
USAGE
}

MODE="${1:-}"
case "$MODE" in
  render) (( $# == 2 )) || { usage >&2; exit 2; } ;;
  apply) (( $# <= 2 )) || { usage >&2; exit 2; } ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

load_versions
require_env IMAGE GIT_COMMIT
require_cmd kustomize jq

[[ "$IMAGE" =~ ^[a-z0-9./_-]+(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]{64})?$ ]] || die "IMAGE invalida: $IMAGE" 2
[[ "$IMAGE" != *:latest ]] || die "no se permite desplegar la etiqueta latest" 2
[[ "$GIT_COMMIT" =~ ^[a-f0-9]{7,40}$ ]] || die "GIT_COMMIT invalido: $GIT_COMMIT" 2

REVISION="${GIT_COMMIT:0:12}"
APP_VERSION="${APP_VERSION:-1.0.0-$REVISION}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
OUTPUT="${2:-$(mktemp --suffix=.yaml)}"
[[ "$OUTPUT" == /* ]] || OUTPUT="$PWD/$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")" || die "no se pudo crear el directorio de $OUTPUT"

WORK_DIR="$(mktemp -d)" || die "no se pudo crear directorio temporal"
trap 'rm -rf -- "$WORK_DIR"' EXIT

render() {
  local patch
  cp -R "$REPO_ROOT/k8s" "$WORK_DIR/k8s"
  patch="$(jq -cn \
    --arg commit "$GIT_COMMIT" \
    --arg version "$APP_VERSION" \
    --arg revision "$REVISION" \
    '[
      {op: "add", path: "/spec/template/metadata/labels/app.kubernetes.io~1version", value: $revision},
      {op: "add", path: "/metadata/annotations", value: {"kubernetes.io/change-cause": ("deploy " + $commit)}},
      {op: "add", path: "/spec/template/spec/containers/0/env/-", value: {name: "GIT_COMMIT", value: $commit}},
      {op: "add", path: "/spec/template/spec/containers/0/env/-", value: {name: "APP_VERSION", value: $version}}
    ]')"
  (
    cd "$WORK_DIR/k8s"
    kustomize edit set image "order-manager=$IMAGE"
    kustomize edit add patch --kind Deployment --name order-manager --patch "$patch"
    kustomize build . >"$OUTPUT"
  ) || die "fallo el renderizado de Kustomize"
  log_info "manifiestos renderizados en $OUTPUT (imagen $IMAGE, revision $REVISION)"
}

ensure_preconditions() {
  kubectl get crd gateways.networking.istio.io peerauthentications.security.istio.io >/dev/null \
    || die "Istio no esta instalado en el cluster: ejecutar infra/istio/install.sh"
  kubectl -n "$MESH_NAMESPACE" rollout status deployment/istiod --timeout=60s >/dev/null \
    || die "istiod no esta disponible en $MESH_NAMESPACE"
}

ensure_namespace_and_secret() {
  local secret_file
  kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml" >/dev/null || die "no se pudo aplicar el namespace"
  if kubectl -n "$APP_NAMESPACE" get secret order-manager-db >/dev/null 2>&1; then
    log_info "secreto order-manager-db existente, se conserva"
    return
  fi
  secret_file="$WORK_DIR/db-password"
  (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$secret_file") || die "no se pudo generar la clave de BD"
  kubectl -n "$APP_NAMESPACE" create secret generic order-manager-db --from-file=DB_PASSWORD="$secret_file" >/dev/null \
    || die "no se pudo crear el secreto order-manager-db"
  log_info "secreto order-manager-db creado"
}

apply_manifests() {
  kubectl apply -f "$OUTPUT" || die "kubectl apply fallo"
  kubectl -n "$APP_NAMESPACE" rollout status statefulset/postgres --timeout="$ROLLOUT_TIMEOUT" \
    || die "rollout de postgres no completado"
  kubectl -n "$APP_NAMESPACE" rollout status deployment/order-manager --timeout="$ROLLOUT_TIMEOUT" \
    || die "rollout de order-manager no completado"
  kubectl -n "$APP_NAMESPACE" get pods -o wide
}

render
if [[ "$MODE" == "apply" ]]; then
  require_cmd kubectl openssl
  ensure_preconditions
  ensure_namespace_and_secret
  apply_manifests
fi
