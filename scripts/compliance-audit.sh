#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Uso: compliance-audit.sh [ARCHIVO_REPORTE_JSON]

Auditoria automatizada de cumplimiento del repositorio. Termina con codigo 1 si algun
control obligatorio falla, lo que detiene el pipeline.

Controles:
  CI-01  Acciones de terceros fijadas por SHA de commit
  CI-02  Workflows con permisos explicitos (principio de minimo privilegio)
  CI-03  Quality gate de SonarQube bloqueante (sonar.qualitygate.wait=true)
  CI-04  Umbral de cobertura JaCoCo >= 80%
  SC-01  Imagen ejecutada con usuario no root y con HEALTHCHECK
  SC-02  Imagenes base sin etiqueta latest
  SC-03  Excepciones de Trivy justificadas y con fecha de expiracion vigente
  SC-04  Sin archivos .env ni llaves privadas versionadas
  SC-05  Dependabot configurado
  GH-01  Reglas de proteccion de la rama main (requiere GH_TOKEN y GITHUB_REPOSITORY)

Variables de entorno:
  GH_TOKEN               Token para consultar la API de GitHub
  GITHUB_REPOSITORY      owner/repo
  REQUIRE_BRANCH_RULES   true para exigir GH-01 (por defecto true si hay GH_TOKEN)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
(( $# <= 1 )) || { usage >&2; exit 2; }

require_cmd git jq grep awk date
REPORT="${1:-$REPO_ROOT/compliance-report.json}"
cd "$REPO_ROOT"

RESULTS="[]"
FAILED=0

record() {
  local id="$1" status="$2" title="$3" detail="$4"
  RESULTS="$(jq -c --arg id "$id" --arg s "$status" --arg t "$title" --arg d "$detail" \
    '. + [{id: $id, status: $s, control: $t, detail: $d}]' <<<"$RESULTS")"
  [[ "$status" == "FAIL" ]] && FAILED=$((FAILED + 1))
  printf '[%s] %s %s: %s\n' "$status" "$id" "$title" "$detail"
}

workflow_files() {
  find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort
}

ci_01() {
  local offenders
  offenders="$(workflow_files | xargs -r grep -nE '^\s*-?\s*uses:\s*' \
    | grep -vE 'uses:\s*\./' \
    | grep -vE 'uses:\s*[^@[:space:]]+@[0-9a-f]{40}(\s|$)' || true)"
  if [[ -z "$offenders" ]]; then
    record CI-01 PASS "Acciones fijadas por SHA" "todas las acciones externas usan un SHA de 40 caracteres"
  else
    record CI-01 FAIL "Acciones fijadas por SHA" "$(tr '\n' ';' <<<"$offenders")"
  fi
}

ci_02() {
  local missing=() file
  while IFS= read -r file; do
    [[ "$file" == .github/actions/* ]] && continue
    grep -qE '^permissions:' "$file" || missing+=("$file")
  done < <(workflow_files)
  if (( ${#missing[@]} == 0 )); then
    record CI-02 PASS "Permisos explicitos en workflows" "todos los workflows declaran permissions a nivel raiz"
  else
    record CI-02 FAIL "Permisos explicitos en workflows" "sin permissions: ${missing[*]}"
  fi
}

ci_03() {
  if grep -qE '<sonar.qualitygate.wait>true</sonar.qualitygate.wait>' pom.xml; then
    record CI-03 PASS "Quality gate de SonarQube bloqueante" "sonar.qualitygate.wait=true"
  else
    record CI-03 FAIL "Quality gate de SonarQube bloqueante" "sonar.qualitygate.wait no es true en pom.xml"
  fi
}

ci_04() {
  local value
  value="$(grep -oE '<jacoco.minimum.line.coverage>[0-9.]+' pom.xml | grep -oE '[0-9.]+$' || true)"
  if [[ -n "$value" ]] && awk -v v="$value" 'BEGIN { exit !(v >= 0.80) }'; then
    record CI-04 PASS "Umbral de cobertura" "jacoco.minimum.line.coverage=$value"
  else
    record CI-04 FAIL "Umbral de cobertura" "umbral ausente o menor a 0.80 (${value:-sin valor})"
  fi
}

sc_01() {
  local user
  user="$(grep -E '^USER\s+' Dockerfile | tail -n 1 | awk '{print $2}')"
  if [[ -n "$user" && "$user" != "root" && "$user" != "0" ]] && grep -qE '^HEALTHCHECK\s' Dockerfile; then
    record SC-01 PASS "Contenedor no root con HEALTHCHECK" "USER $user"
  else
    record SC-01 FAIL "Contenedor no root con HEALTHCHECK" "USER='${user:-ausente}' o HEALTHCHECK ausente"
  fi
}

sc_02() {
  local bad
  bad="$(awk '
    toupper($1) == "FROM" {
      image = ""
      for (i = 2; i <= NF; i++) { if ($i !~ /^--/) { image = $i; break } }
      for (i = 1; i <= NF; i++) { if (toupper($i) == "AS" && i < NF) alias[tolower($(i + 1))] = 1 }
      if (image == "" || (tolower(image) in alias) || image == "scratch") next
      if (image ~ /@sha256:/) next
      n = split(image, parts, "/")
      if (parts[n] !~ /:/ || image ~ /:latest$/) print NR ": " image
    }' Dockerfile)"
  if [[ -z "$bad" ]]; then
    record SC-02 PASS "Imagenes base con version fija" "$(grep -ciE '^FROM' Dockerfile) etapas FROM con etiqueta o digest explicito"
  else
    record SC-02 FAIL "Imagenes base con version fija" "$(tr '\n' ';' <<<"$bad")"
  fi
}

sc_03() {
  local file=.trivyignore.yaml ids statements expirations today expired
  if [[ ! -f "$file" ]]; then
    record SC-03 PASS "Excepciones de Trivy controladas" "sin excepciones"
    return
  fi
  ids="$(grep -cE '^\s*-\s*id:' "$file" || true)"
  statements="$(grep -cE '^\s*statement:' "$file" || true)"
  expirations="$(grep -cE '^\s*expired_at:' "$file" || true)"
  today="$(date -u +%Y-%m-%d)"
  expired="$(grep -oE 'expired_at:\s*[0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" | awk -v t="$today" '{ if ($2 < t) print $2 }' | tr '\n' ' ')"
  if [[ "$ids" == "$statements" && "$ids" == "$expirations" && -z "$expired" ]]; then
    record SC-03 PASS "Excepciones de Trivy controladas" "$ids excepciones justificadas y vigentes"
  else
    record SC-03 FAIL "Excepciones de Trivy controladas" "ids=$ids statements=$statements expired_at=$expirations vencidas=[${expired}]"
  fi
}

sc_04() {
  local tracked
  tracked="$(git ls-files | grep -E '(^|/)\.env(\.[^/]*)?$|\.pem$|\.key$|id_rsa' | grep -vE '\.env\.example$' || true)"
  if [[ -z "$tracked" ]]; then
    record SC-04 PASS "Sin secretos versionados" "no hay .env, .pem, .key ni llaves privadas en git"
  else
    record SC-04 FAIL "Sin secretos versionados" "$(tr '\n' ' ' <<<"$tracked")"
  fi
}

sc_05() {
  if [[ -f .github/dependabot.yml ]] && grep -qE 'package-ecosystem:\s*maven' .github/dependabot.yml; then
    record SC-05 PASS "Dependabot configurado" "$(grep -cE 'package-ecosystem:' .github/dependabot.yml) ecosistemas monitoreados"
  else
    record SC-05 FAIL "Dependabot configurado" ".github/dependabot.yml ausente o sin maven"
  fi
}

gh_01() {
  local require="${REQUIRE_BRANCH_RULES:-}" response code body types missing=()
  if [[ -z "${GH_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
    if [[ "$require" == "true" ]]; then
      record GH-01 FAIL "Proteccion de la rama main" "GH_TOKEN o GITHUB_REPOSITORY no definidos"
    else
      record GH-01 SKIP "Proteccion de la rama main" "sin acceso a la API de GitHub en esta ejecucion"
    fi
    return
  fi
  require_cmd curl
  response="$(curl -sS --max-time 20 -w '\n%{http_code}' \
    -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/rules/branches/main")" \
    || { record GH-01 FAIL "Proteccion de la rama main" "no se pudo consultar la API de GitHub"; return; }
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$code" != "200" ]]; then
    record GH-01 FAIL "Proteccion de la rama main" "API de GitHub respondio HTTP $code"
    return
  fi
  types="$(jq -r '[.[].type] | unique | join(",")' <<<"$body")"
  for rule in pull_request required_status_checks non_fast_forward deletion; do
    [[ ",$types," == *",$rule,"* ]] || missing+=("$rule")
  done
  if (( ${#missing[@]} == 0 )); then
    record GH-01 PASS "Proteccion de la rama main" "reglas activas: $types"
  else
    record GH-01 FAIL "Proteccion de la rama main" "faltan reglas: ${missing[*]} (ejecutar scripts/branch-protection.sh)"
  fi
}

ci_01
ci_02
ci_03
ci_04
sc_01
sc_02
sc_03
sc_04
sc_05
gh_01

jq -n --argjson results "$RESULTS" --arg repo "${GITHUB_REPOSITORY:-local}" \
  --arg commit "$(git rev-parse HEAD 2>/dev/null || echo unknown)" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{repository: $repo, commit: $commit, generated_at: $date,
    passed: ([$results[] | select(.status == "PASS")] | length),
    failed: ([$results[] | select(.status == "FAIL")] | length),
    skipped: ([$results[] | select(.status == "SKIP")] | length),
    controls: $results}' >"$REPORT" || die "no se pudo escribir el reporte $REPORT"

summary "### Auditoria de cumplimiento" "" "| Estado | Control | Descripcion | Detalle |" "|---|---|---|---|" \
  "$(jq -r '.[] | "| \(.status) | \(.id) | \(.control) | \(.detail | gsub("\\|"; "\\\\|")) |"' <<<"$RESULTS")" ""

log_info "reporte: $REPORT"
(( FAILED == 0 )) || die "$FAILED controles de cumplimiento fallaron"
