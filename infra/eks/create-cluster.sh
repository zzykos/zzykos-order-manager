#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: infra/eks/create-cluster.sh [--dry-run]

Crea el cluster EKS definido en infra/eks/cluster-template.yaml usando el rol LabRole
de AWS Academy Learner Lab para el plano de control y los nodos, y configura kubectl.

  --dry-run   Solo renderiza la configuracion de eksctl y la muestra.

Requiere credenciales validas (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
o ~/.aws/credentials) y las herramientas aws, eksctl, kubectl y envsubst.
USAGE
}

DRY_RUN=false
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

load_versions
require_cmd aws envsubst jq

IDENTITY="$(aws sts get-caller-identity --output json 2>&1)" \
  || die "credenciales de AWS invalidas o expiradas: $IDENTITY"
AWS_ACCOUNT_ID="$(jq -r '.Account' <<<"$IDENTITY")"
export AWS_ACCOUNT_ID
log_info "identidad: $(jq -r '.Arn' <<<"$IDENTITY")"

aws iam get-role --role-name LabRole >/dev/null 2>&1 \
  || die "el rol LabRole no existe en la cuenta $AWS_ACCOUNT_ID (requerido en Learner Lab)"

CONFIG="$(mktemp --suffix=.yaml)" || die "no se pudo crear archivo temporal"
trap 'rm -f -- "$CONFIG"' EXIT
envsubst '${CLUSTER_NAME} ${AWS_REGION} ${EKS_VERSION} ${AWS_ACCOUNT_ID}' \
  <"$REPO_ROOT/infra/eks/cluster-template.yaml" >"$CONFIG"

if [[ "$DRY_RUN" == "true" ]]; then
  cat "$CONFIG"
  exit 0
fi

require_cmd eksctl kubectl

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  log_info "el cluster $CLUSTER_NAME ya existe, se omite la creacion"
else
  log_info "creando cluster $CLUSTER_NAME (EKS $EKS_VERSION) en $AWS_REGION; toma entre 15 y 25 minutos"
  eksctl create cluster -f "$CONFIG" || die "eksctl no pudo crear el cluster"
fi

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null \
  || die "no se pudo actualizar kubeconfig"
kubectl wait --for=condition=Ready nodes --all --timeout=300s || die "los nodos no quedaron Ready"
kubectl get nodes -o wide
