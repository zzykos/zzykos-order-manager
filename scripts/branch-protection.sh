#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: branch-protection.sh [--dry-run] OWNER/REPO

Crea o actualiza el ruleset "proteccion-main" sobre la rama por defecto:
  - cambios solo mediante pull request con aprobaciones y conversaciones resueltas
  - aprobaciones invalidadas ante nuevos commits
  - checks obligatorios del pipeline CI/CD (pruebas, SAST, SCA, politicas, auditoria, imagen)
  - prohibe force push y eliminacion de la rama, exige historial lineal

Variables de entorno:
  GH_TOKEN             Token con permiso de administracion del repositorio (obligatoria salvo --dry-run)
  REQUIRED_APPROVALS   Aprobaciones requeridas en cada pull request (por defecto 1)
USAGE
}

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# == 1 )) || { usage >&2; exit 2; }

REPO="$1"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repositorio invalido: $REPO" 2
require_cmd curl jq
REQUIRED_APPROVALS="${REQUIRED_APPROVALS:-1}"
[[ "$REQUIRED_APPROVALS" =~ ^[0-9]$ ]] || die "REQUIRED_APPROVALS debe ser un entero entre 0 y 9" 2

API="https://api.github.com/repos/$REPO"
RULESET_NAME="proteccion-main"
GITHUB_ACTIONS_APP_ID=15368
REQUIRED_CHECKS=(
  "1 · Pruebas (JUnit + JaCoCo)"
  "2 · SAST (SonarQube Cloud)"
  "3 · SCA (Trivy fs)"
  "Kubernetes · Validación de manifiestos y políticas"
  "Cumplimiento · Auditoría del repositorio"
  "4 · Imagen Docker (build, scan, push)"
)

PAYLOAD="$(jq -n \
  --arg name "$RULESET_NAME" \
  --argjson app "$GITHUB_ACTIONS_APP_ID" \
  --argjson approvals "$REQUIRED_APPROVALS" \
  --args '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "required_linear_history"},
      {type: "pull_request", parameters: {
        required_approving_review_count: $approvals,
        dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false,
        require_last_push_approval: ($approvals > 0),
        required_review_thread_resolution: true
      }},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: true,
        do_not_enforce_on_create: false,
        required_status_checks: [$ARGS.positional[] | {context: ., integration_id: $app}]
      }}
    ]
  }' "${REQUIRED_CHECKS[@]}")"

if [[ "$DRY_RUN" == "true" ]]; then
  jq . <<<"$PAYLOAD"
  exit 0
fi

require_env GH_TOKEN

github() {
  local method="$1" path="$2" data="${3:-}" response code body
  local -a args=(-sS --max-time 30 -w '\n%{http_code}' -X "$method"
    -H "Authorization: Bearer $GH_TOKEN"
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28')
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$data")
  response="$(curl "${args[@]}" "$API$path")" || die "no se pudo contactar a la API de GitHub ($method $path)"
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ "$code" =~ ^2 ]] || die "GitHub respondio HTTP $code en $method $path: $(jq -r '.message // .' <<<"$body" 2>/dev/null)"
  printf '%s' "$body"
}

EXISTING_ID="$(github GET "/rulesets?includes_parents=false&per_page=100" \
  | jq -r --arg n "$RULESET_NAME" '.[] | select(.name == $n) | .id' | head -n 1)"

if [[ -n "$EXISTING_ID" ]]; then
  RESULT="$(github PUT "/rulesets/$EXISTING_ID" "$PAYLOAD")"
  log_info "ruleset actualizado (id $EXISTING_ID)"
else
  RESULT="$(github POST "/rulesets" "$PAYLOAD")"
  log_info "ruleset creado (id $(jq -r '.id' <<<"$RESULT"))"
fi

jq -r '"reglas activas: " + ([.rules[].type] | join(", "))' <<<"$RESULT"
