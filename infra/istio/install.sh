#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: infra/istio/install.sh

Instala Istio (version de infra/versions.env) con el perfil demo, recursos minimos,
Istio CNI (compatible con Pod Security restricted) y telemetria de malla.

Variables de entorno:
  INGRESS_SERVICE_TYPE   Tipo de Service del ingress gateway: ClusterIP (por defecto) o LoadBalancer
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 0 )) || { usage >&2; exit 2; }

load_versions
require_cmd istioctl kubectl envsubst jq

INGRESS_SERVICE_TYPE="${INGRESS_SERVICE_TYPE:-ClusterIP}"
[[ "$INGRESS_SERVICE_TYPE" =~ ^(ClusterIP|LoadBalancer)$ ]] \
  || die "INGRESS_SERVICE_TYPE debe ser ClusterIP o LoadBalancer" 2
export INGRESS_SERVICE_TYPE

CLIENT_VERSION="$(istioctl version --remote=false -o json | jq -r '.clientVersion.version')"
[[ "$CLIENT_VERSION" == "$ISTIO_VERSION" ]] \
  || die "istioctl $CLIENT_VERSION no coincide con ISTIO_VERSION=$ISTIO_VERSION (usar scripts/install-tools.sh istioctl)"

kubectl get nodes >/dev/null || die "kubectl no tiene acceso al cluster"

OPERATOR="$(mktemp --suffix=.yaml)" || die "no se pudo crear archivo temporal"
trap 'rm -f -- "$OPERATOR"' EXIT
envsubst '${INGRESS_SERVICE_TYPE}' <"$REPO_ROOT/infra/istio/istio-operator.yaml" >"$OPERATOR"

istioctl x precheck || die "el precheck de Istio fallo"
istioctl install -f "$OPERATOR" -y || die "istioctl install fallo"

kubectl -n "$MESH_NAMESPACE" rollout status deployment/istiod --timeout=300s
kubectl -n "$MESH_NAMESPACE" rollout status deployment/istio-ingressgateway --timeout=300s
kubectl -n "$MESH_NAMESPACE" rollout status daemonset/istio-cni-node --timeout=300s

kubectl apply -f "$REPO_ROOT/infra/istio/telemetry-mesh.yaml" || die "no se pudo aplicar la telemetria de malla"

kubectl -n "$MESH_NAMESPACE" get pods
log_info "Istio $ISTIO_VERSION instalado (ingress gateway: $INGRESS_SERVICE_TYPE)"
