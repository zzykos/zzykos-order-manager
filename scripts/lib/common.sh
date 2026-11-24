#!/usr/bin/env bash

if [[ -n "${ORDER_MANAGER_COMMON_LOADED:-}" ]]; then
  return 0
fi
readonly ORDER_MANAGER_COMMON_LOADED=1

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/../.." && pwd)"
readonly COMMON_DIR REPO_ROOT

PORT_FORWARD_PIDS=()

log_info() {
  printf '[%s] INFO  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

log_warn() {
  printf '[%s] WARN  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::warning::%s\n' "$*"
  fi
}

log_error() {
  printf '[%s] ERROR %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::error::%s\n' "$*"
  fi
}

die() {
  log_error "$1"
  exit "${2:-1}"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "dependencia requerida no encontrada: $cmd" 2
  done
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "variable de entorno requerida no definida: $name" 2
  done
}

load_versions() {
  local file="$REPO_ROOT/infra/versions.conf" line key value
  [[ -r "$file" ]] || die "no se puede leer $file" 2
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "linea invalida en $file: $line" 2
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -z "${!key:-}" ]]; then
      printf -v "$key" '%s' "$value"
      export "${key?}"
    fi
  done <"$file"
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY" || log_warn "no se pudo escribir en GITHUB_STEP_SUMMARY"
  fi
}

wait_for_port() {
  local port="$1" timeout="${2:-30}" elapsed=0
  while (( elapsed < timeout )); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

start_port_forward() {
  local namespace="$1" target="$2" mapping="$3" log_file pid local_port
  local_port="${mapping%%:*}"
  log_file="$(mktemp)" || die "no se pudo crear archivo temporal para port-forward"
  kubectl -n "$namespace" port-forward "$target" "$mapping" --address 127.0.0.1 >"$log_file" 2>&1 &
  pid=$!
  PORT_FORWARD_PIDS+=("$pid")
  if ! wait_for_port "$local_port" "${PORT_FORWARD_TIMEOUT:-45}"; then
    log_error "port-forward $namespace/$target ($mapping) no disponible"
    cat "$log_file" >&2
    rm -f -- "$log_file"
    return 1
  fi
  rm -f -- "$log_file"
  log_info "port-forward activo: 127.0.0.1:$local_port -> $namespace/$target"
}

stop_port_forwards() {
  local pid
  for pid in "${PORT_FORWARD_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || log_warn "no se pudo detener el port-forward $pid"
      wait "$pid" 2>/dev/null || true
    fi
  done
  PORT_FORWARD_PIDS=()
}
