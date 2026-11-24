#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: verify-mesh.sh

Verifica en el cluster que el namespace de la aplicacion cumple las politicas de la malla:
inyeccion del sidecar, mTLS STRICT, denegacion por defecto, validacion de istioctl analyze
y rechazo de trafico en texto plano desde fuera de la malla.

Variables de entorno:
  VERIFY_PLAINTEXT_DENIED   false para omitir la prueba de trafico en texto plano (por defecto true)
  PROBE_IMAGE               Imagen usada para la prueba (por defecto docker.io/curlimages/curl:8.11.1)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 0 )) || { usage >&2; exit 2; }

load_versions
require_cmd kubectl istioctl jq

VERIFY_PLAINTEXT_DENIED="${VERIFY_PLAINTEXT_DENIED:-true}"
PROBE_IMAGE="${PROBE_IMAGE:-docker.io/curlimages/curl:8.11.1}"
PASSED=0
FAILED=0
ROWS=()

check() {
  local outcome="$1" description="$2" detail="$3"
  if [[ "$outcome" == "PASS" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  ROWS+=("| $outcome | $description | ${detail//|/\\|} |")
  printf '[%s] %s (%s)\n' "$outcome" "$description" "$detail"
}

check_injection_label() {
  local label
  label="$(kubectl get namespace "$APP_NAMESPACE" -o jsonpath='{.metadata.labels.istio-injection}')"
  if [[ "$label" == "enabled" ]]; then
    check PASS "Namespace con inyeccion automatica del sidecar" "istio-injection=$label"
  else
    check FAIL "Namespace con inyeccion automatica del sidecar" "istio-injection='${label:-ausente}'"
  fi
}

check_sidecars() {
  local pods missing
  pods="$(kubectl -n "$APP_NAMESPACE" get pods --field-selector=status.phase=Running -o json)"
  missing="$(jq -r '[.items[] | select(([.spec.containers[].name, (.spec.initContainers // [])[].name] | index("istio-proxy")) | not) | .metadata.name] | join(",")' <<<"$pods")"
  if [[ -z "$missing" && "$(jq '.items | length' <<<"$pods")" -gt 0 ]]; then
    check PASS "Todos los pods tienen el proxy istio-proxy" "$(jq -r '[.items[] | "\(.metadata.name) \([.status.containerStatuses[] | select(.ready)] | length)/\(.spec.containers | length)"] | join(", ")' <<<"$pods")"
  else
    check FAIL "Todos los pods tienen el proxy istio-proxy" "sin sidecar: ${missing:-no hay pods en ejecucion}"
  fi
}

check_mtls() {
  local mode
  mode="$(kubectl -n "$APP_NAMESPACE" get peerauthentication default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || true)"
  if [[ "$mode" == "STRICT" ]]; then
    check PASS "PeerAuthentication en modo STRICT" "mtls.mode=$mode"
  else
    check FAIL "PeerAuthentication en modo STRICT" "mtls.mode='${mode:-ausente}'"
  fi
}

check_default_deny() {
  if kubectl -n "$APP_NAMESPACE" get authorizationpolicy allow-nothing >/dev/null 2>&1; then
    check PASS "AuthorizationPolicy de denegacion por defecto" "allow-nothing presente"
  else
    check FAIL "AuthorizationPolicy de denegacion por defecto" "allow-nothing ausente"
  fi
}

check_analyze() {
  local output
  if output="$(istioctl analyze -n "$APP_NAMESPACE" --failure-threshold Error 2>&1)"; then
    check PASS "istioctl analyze sin errores de configuracion" "$(head -n 1 <<<"$output")"
  else
    check FAIL "istioctl analyze sin errores de configuracion" "$(tr '\n' ' ' <<<"$output" | cut -c1-300)"
  fi
}

check_plaintext_denied() {
  local probe_ns="mesh-probe-$RANDOM" code
  kubectl create namespace "$probe_ns" >/dev/null || { check FAIL "Trafico sin mTLS rechazado" "no se pudo crear $probe_ns"; return; }
  code="$(kubectl -n "$probe_ns" run probe --image="$PROBE_IMAGE" --restart=Never --rm -i --quiet \
    --command -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://order-manager.${APP_NAMESPACE}.svc.cluster.local/api/orders" 2>/dev/null || true)"
  kubectl delete namespace "$probe_ns" --wait=false >/dev/null || log_warn "no se pudo eliminar $probe_ns"
  code="$(tr -dc '0-9' <<<"$code")"
  if [[ "$code" == "200" ]]; then
    check FAIL "Trafico sin mTLS desde fuera de la malla rechazado" "respondio HTTP 200"
  elif [[ -z "$code" ]]; then
    check FAIL "Trafico sin mTLS desde fuera de la malla rechazado" "la prueba no se pudo ejecutar"
  else
    check PASS "Trafico sin mTLS desde fuera de la malla rechazado" "resultado HTTP ${code}"
  fi
}

check_injection_label
check_sidecars
check_mtls
check_default_deny
check_analyze
if [[ "$VERIFY_PLAINTEXT_DENIED" == "true" ]]; then
  check_plaintext_denied
fi

summary "### Verificacion de la malla de servicios (Istio)" "" "| Estado | Control | Detalle |" "|---|---|---|" "${ROWS[@]}" "" "**$PASSED aprobados, $FAILED fallidos**" ""
printf 'Resultado: %d aprobados, %d fallidos\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
