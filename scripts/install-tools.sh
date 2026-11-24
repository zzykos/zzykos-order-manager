#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: install-tools.sh HERRAMIENTA [HERRAMIENTA...]

Instala binarios con version fijada en infra/versions.env y verificacion SHA-256.

Herramientas: istioctl, kustomize, conftest, eksctl

Variables de entorno:
  TOOLS_BIN   Directorio de instalacion (por defecto $HOME/.local/bin)
USAGE
}

(( $# > 0 )) || { usage >&2; exit 2; }
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd curl tar sha256sum uname
load_versions

TOOLS_BIN="${TOOLS_BIN:-$HOME/.local/bin}"
mkdir -p "$TOOLS_BIN" || die "no se pudo crear $TOOLS_BIN"

case "$(uname -s)" in
  Linux) OS_LOWER=linux; OS_TITLE=Linux ;;
  Darwin) OS_LOWER=osx; OS_TITLE=Darwin ;;
  *) die "sistema operativo no soportado: $(uname -s)" 2 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64; ARCH_ALT=x86_64 ;;
  aarch64 | arm64) ARCH=arm64; ARCH_ALT=arm64 ;;
  *) die "arquitectura no soportada: $(uname -m)" 2 ;;
esac

WORK_DIR="$(mktemp -d)" || die "no se pudo crear directorio temporal"
trap 'rm -rf -- "$WORK_DIR"' EXIT

fetch() {
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || die "descarga fallida: $1"
}

verify_from_list() {
  local file="$1" list="$2" name="$3" expected
  expected="$(awk -v n="$name" '$2 == n || $2 == "*"n {print $1}' "$list" | head -n 1)"
  [[ -n "$expected" ]] || die "no se encontro el checksum de $name"
  printf '%s  %s\n' "$expected" "$file" | sha256sum -c --status - || die "checksum invalido para $name"
}

install_istioctl() {
  local suffix name base
  case "$OS_LOWER-$ARCH" in
    linux-*) suffix="linux-$ARCH" ;;
    osx-amd64) suffix="osx" ;;
    osx-arm64) suffix="osx-arm64" ;;
  esac
  name="istioctl-${ISTIO_VERSION}-${suffix}.tar.gz"
  base="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}"
  fetch "$base/$name" "$WORK_DIR/$name"
  fetch "$base/$name.sha256" "$WORK_DIR/$name.sha256"
  verify_from_list "$WORK_DIR/$name" "$WORK_DIR/$name.sha256" "$name"
  tar -xzf "$WORK_DIR/$name" -C "$WORK_DIR" istioctl
  install -m 0755 "$WORK_DIR/istioctl" "$TOOLS_BIN/istioctl"
}

install_kustomize() {
  local os="${OS_LOWER/osx/darwin}" name base
  name="kustomize_v${KUSTOMIZE_VERSION}_${os}_${ARCH}.tar.gz"
  base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}"
  fetch "$base/$name" "$WORK_DIR/$name"
  fetch "$base/checksums.txt" "$WORK_DIR/kustomize-checksums.txt"
  verify_from_list "$WORK_DIR/$name" "$WORK_DIR/kustomize-checksums.txt" "$name"
  tar -xzf "$WORK_DIR/$name" -C "$WORK_DIR" kustomize
  install -m 0755 "$WORK_DIR/kustomize" "$TOOLS_BIN/kustomize"
}

install_conftest() {
  local name base
  name="conftest_${CONFTEST_VERSION}_${OS_TITLE}_${ARCH_ALT}.tar.gz"
  base="https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}"
  fetch "$base/$name" "$WORK_DIR/$name"
  fetch "$base/checksums.txt" "$WORK_DIR/conftest-checksums.txt"
  verify_from_list "$WORK_DIR/$name" "$WORK_DIR/conftest-checksums.txt" "$name"
  tar -xzf "$WORK_DIR/$name" -C "$WORK_DIR" conftest
  install -m 0755 "$WORK_DIR/conftest" "$TOOLS_BIN/conftest"
}

install_eksctl() {
  local name base
  name="eksctl_${OS_TITLE}_${ARCH}.tar.gz"
  base="https://github.com/eksctl-io/eksctl/releases/download/v${EKSCTL_VERSION}"
  fetch "$base/$name" "$WORK_DIR/$name"
  fetch "$base/eksctl_checksums.txt" "$WORK_DIR/eksctl-checksums.txt"
  verify_from_list "$WORK_DIR/$name" "$WORK_DIR/eksctl-checksums.txt" "$name"
  tar -xzf "$WORK_DIR/$name" -C "$WORK_DIR" eksctl
  install -m 0755 "$WORK_DIR/eksctl" "$TOOLS_BIN/eksctl"
}

for tool in "$@"; do
  case "$tool" in
    istioctl) install_istioctl; "$TOOLS_BIN/istioctl" version --remote=false >&2 ;;
    kustomize) install_kustomize; "$TOOLS_BIN/kustomize" version >&2 ;;
    conftest) install_conftest; "$TOOLS_BIN/conftest" --version >&2 ;;
    eksctl) install_eksctl; "$TOOLS_BIN/eksctl" version >&2 ;;
    *) usage >&2; die "herramienta desconocida: $tool" 2 ;;
  esac
  log_info "$tool instalado en $TOOLS_BIN"
done

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$TOOLS_BIN" >>"$GITHUB_PATH"
fi
