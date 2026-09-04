#!/usr/bin/env bash
# Ultimo recurso del auto-arreglo: le pasa el problema a Claude Code en modo headless.
# Lo llama scripts/watchdog.sh cuando su propio playbook no alcanzo, y SOLO si el .env de la
# VM tiene CLAUDE_AUTOREPAIR=1. Nunca lo corre nadie mas.
#
#   scripts/autorepair.sh --bundle data/diagnostico/20260904-0312 --motivo crash-loop --intentos 1
#   DRY_RUN=1 scripts/autorepair.sh ...   # imprime el comando y el prompt, sin llamar a Claude
#
# Claude arranca con cd en el repo, con las herramientas restringidas a lo operativo
# (--allowedTools) y con las reglas duras de tools/autorepair/CLAUDE.md agregadas al system
# prompt. Todo lo que no este en la lista se le deniega solo: en modo -p no hay nadie a quien
# preguntarle. Ver docs/self-healing.md para el porque de cada restriccion.
#
# Sintaxis verificada contra la documentacion oficial (2026-09-04):
#   https://code.claude.com/docs/en/headless
#   https://code.claude.com/docs/en/cli-reference
#   https://code.claude.com/docs/en/authentication
set -euo pipefail

REPO_DIR="${AUTOREPAIR_REPO_DIR:-${WATCHDOG_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
cd "${REPO_DIR}"

STATE_DIR="${WATCHDOG_STATE_DIR:-/var/tmp/zomboid-watchdog}"
LOG_FILE="${WATCHDOG_LOG:-/var/log/zomboid/watchdog.log}"
DRY_RUN="${DRY_RUN:-0}"

NOTIF_LOG="${LOG_FILE}"
NOTIF_PREFIJO="autorepair"
# shellcheck source=scripts/lib/notificar.sh
source "${REPO_DIR}/scripts/lib/notificar.sh"

# Codigos de salida (los mira el watchdog, que solo los loguea).
EXIT_OK=0
EXIT_CLAUDE_FALLO=1
EXIT_DESACTIVADO=3
EXIT_SIN_CLI=4
EXIT_SIN_CREDENCIAL=5
EXIT_SIN_CUPO=6

BUNDLE=""
MOTIVO="desconocido"
INTENTOS=1

uso() {
  cat <<MSG
uso: scripts/autorepair.sh --bundle <dir> --motivo <texto> [--intentos <n>]

  --bundle    directorio del diagnostico que armo el watchdog (obligatorio)
  --motivo    que detecto el watchdog: crash-loop, patron-fatal, oom, rcon, disco
  --intentos  cuantas veces se escalo hoy por el mismo motivo (default 1)
MSG
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --motivo) MOTIVO="${2:-}"; shift 2 ;;
    --intentos) INTENTOS="${2:-1}"; shift 2 ;;
    -h | --help) uso; exit 0 ;;
    *) uso >&2; echo "autorepair: opcion desconocida: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "${STATE_DIR}"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_DIR}/.env"
  set +a
fi

MAX_POR_DIA="${AUTOREPAIR_MAX_PER_DAY:-3}"
MAX_POR_HORA="${AUTOREPAIR_MAX_PER_HOUR:-1}"
MAX_TURNS="${AUTOREPAIR_MAX_TURNS:-40}"
TIMEOUT="${AUTOREPAIR_TIMEOUT:-40m}"
MODELO="${AUTOREPAIR_MODEL:-}"
MODO_PERMISOS="${AUTOREPAIR_PERMISSION_MODE:-acceptEdits}"

# --- Guardas ----------------------------------------------------------------------------------

if [[ "${CLAUDE_AUTOREPAIR:-0}" != "1" ]]; then
  log "CLAUDE_AUTOREPAIR no esta en 1 en .env: no se llama a Claude"
  exit "${EXIT_DESACTIVADO}"
fi

if [[ -z "${BUNDLE}" || ! -d "${BUNDLE}" ]]; then
  echo "autorepair: ERROR: --bundle tiene que apuntar a un directorio existente" >&2
  exit 2
fi
BUNDLE="$(cd "${BUNDLE}" && pwd)"

if ! command -v claude >/dev/null 2>&1; then
  notificar error "Auto-arreglo no disponible" \
    "CLAUDE_AUTOREPAIR=1 pero el CLI 'claude' no esta instalado en la VM.
Instalarlo o poner CLAUDE_AUTOREPAIR=0 en .env para dejar de intentarlo.
Diagnostico en ${BUNDLE#"${REPO_DIR}/"} (motivo: ${MOTIVO})."
  exit "${EXIT_SIN_CLI}"
fi

# Las dos formas de autenticar una corrida sin interaccion. ANTHROPIC_API_KEY factura por API;
# CLAUDE_CODE_OAUTH_TOKEN (de 'claude setup-token') usa la suscripcion y dura ~1 ano.
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  notificar error "Auto-arreglo no disponible" \
    "CLAUDE_AUTOREPAIR=1 pero no hay credencial: falta ANTHROPIC_API_KEY o CLAUDE_CODE_OAUTH_TOKEN en .env.
Diagnostico en ${BUNDLE#"${REPO_DIR}/"} (motivo: ${MOTIVO})."
  exit "${EXIT_SIN_CREDENCIAL}"
fi

# Cupo: como mucho una invocacion por hora y tres por dia. El estado son lineas "epoch<TAB>motivo".
MARCAS="${STATE_DIR}/autorepair-invocaciones"
contar_desde() {
  local corte ts n=0
  corte=$(( $(date +%s) - $1 ))
  [[ -f "${MARCAS}" ]] || { echo 0; return 0; }
  while IFS=$'\t' read -r ts _; do
    [[ "${ts}" =~ ^[0-9]+$ ]] && (( ts >= corte )) && n=$(( n + 1 ))
  done < "${MARCAS}"
  echo "${n}"
}

en_hora="$(contar_desde 3600)"
en_dia="$(contar_desde 86400)"
if (( en_hora >= MAX_POR_HORA )) || (( en_dia >= MAX_POR_DIA )); then
  log "sin cupo (${en_hora}/${MAX_POR_HORA} en la ultima hora, ${en_dia}/${MAX_POR_DIA} hoy)"
  notificar warn "Auto-arreglo en pausa" \
    "Ya se agoto el cupo de invocaciones (${en_hora}/${MAX_POR_HORA} por hora, ${en_dia}/${MAX_POR_DIA} por dia).
El server sigue caido por '${MOTIVO}' y necesita a alguien.
Diagnostico en ${BUNDLE#"${REPO_DIR}/"}."
  exit "${EXIT_SIN_CUPO}"
fi

# --- Prompt -----------------------------------------------------------------------------------

PLANTILLA="${REPO_DIR}/tools/autorepair/prompt.md"
REGLAS="${REPO_DIR}/tools/autorepair/CLAUDE.md"
[[ -f "${PLANTILLA}" ]] || { echo "autorepair: falta ${PLANTILLA}" >&2; exit 2; }
[[ -f "${REGLAS}" ]] || { echo "autorepair: falta ${REGLAS}" >&2; exit 2; }

# Los placeholders se reemplazan con awk y no con sed: el valor puede traer barras.
render() {
  awk -v bundle="${BUNDLE}" -v motivo="${MOTIVO}" -v intentos="${INTENTOS}" '
    { gsub(/\{\{BUNDLE_DIR\}\}/, bundle); gsub(/\{\{MOTIVO\}\}/, motivo);
      gsub(/\{\{INTENTOS\}\}/, intentos); print }' "${PLANTILLA}"
}
PROMPT="$(render)"

# Herramientas permitidas. Todo lo demas se deniega solo. Es mas angosto que 'Bash(make:*)'
# a proposito: 'make wipe' y 'make restore' tocan el mundo y no tienen por que estar aca.
HERRAMIENTAS="${AUTOREPAIR_ALLOWED_TOOLS:-Bash(make up:*),Bash(make down:*),Bash(make restart:*),Bash(make render:*),Bash(make status:*),Bash(make logs:*),Bash(docker compose logs:*),Bash(docker compose ps:*),Bash(./scripts/rcon.sh:*),Bash(./scripts/restart.sh:*),Bash(./scripts/stop.sh:*),Bash(./scripts/backup.sh:*),Bash(cat:*),Bash(grep:*),Bash(tail:*),Bash(head:*),Bash(ls:*),Bash(df:*),Bash(free:*),Read,Edit,Grep,Glob}"

SALIDA="${BUNDLE}/autorepair.json"

cmd=(timeout "${TIMEOUT}" claude -p "${PROMPT}"
     --output-format json
     --max-turns "${MAX_TURNS}"
     --permission-mode "${MODO_PERMISOS}"
     --allowedTools "${HERRAMIENTAS}"
     --append-system-prompt "$(cat "${REGLAS}")")
[[ -n "${MODELO}" ]] && cmd+=(--model "${MODELO}")

if [[ "${DRY_RUN}" == "1" ]]; then
  log "DRY_RUN: comando que se correria (el prompt va recortado)"
  printf '  %q' "${cmd[@]:0:3}" | head -c 400
  echo " ... --output-format json --max-turns ${MAX_TURNS} --permission-mode ${MODO_PERMISOS}"
  exit "${EXIT_OK}"
fi

# --- Invocacion --------------------------------------------------------------------------------

printf '%s\t%s\n' "$(date +%s)" "${MOTIVO}" >> "${MARCAS}"
notificar warn "Llamando al auto-arreglo" \
  "Motivo: ${MOTIVO} (escalacion ${INTENTOS} de hoy).
Claude Code va a mirar ${BUNDLE#"${REPO_DIR}/"} y tiene hasta ${TIMEOUT} y ${MAX_TURNS} turnos.
No puede hacer wipe, restore, ni borrar saves: solo reiniciar y corregir configuracion."

log "corriendo claude (timeout ${TIMEOUT}, max-turns ${MAX_TURNS})"
rc=0
"${cmd[@]}" > "${SALIDA}" 2> "${BUNDLE}/autorepair.err" || rc=$?
chmod go-rwx "${SALIDA}" 2>/dev/null || true

# --- Resultado ----------------------------------------------------------------------------------
# El JSON sale igual cuando la corrida falla: lo que dice si fue bien es .is_error.
leer_json() {
  local campo="$1" defecto="$2"
  [[ -s "${SALIDA}" ]] || { echo "${defecto}"; return 0; }
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg d "${defecto}" ".${campo} // \$d" "${SALIDA}" 2>/dev/null || echo "${defecto}"
  else
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(sys.argv[3]); raise SystemExit
v = d.get(sys.argv[2])
print(sys.argv[3] if v is None else v)' "${SALIDA}" "${campo}" "${defecto}"
  fi
}

texto="$(leer_json result '(sin texto: revisar autorepair.json y autorepair.err)')"
costo="$(leer_json total_cost_usd '?')"
turnos="$(leer_json num_turns '?')"
es_error="$(leer_json is_error 'true')"

log "claude salio con ${rc} (is_error=${es_error}, turnos=${turnos}, costo USD ${costo})"

if [[ "${rc}" -eq 124 ]]; then
  notificar error "Auto-arreglo cortado por tiempo" \
    "Claude paso de ${TIMEOUT} sin terminar. El server puede haber quedado a medio arreglar.
Diagnostico y salida parcial en ${BUNDLE#"${REPO_DIR}/"}."
  exit "${EXIT_CLAUDE_FALLO}"
fi

if [[ "${rc}" -ne 0 || "${es_error}" == "true" ]]; then
  notificar error "El auto-arreglo fallo" \
    "claude salio con codigo ${rc} (is_error=${es_error}).
${texto}
Salida completa en ${BUNDLE#"${REPO_DIR}/"}/autorepair.json"
  exit "${EXIT_CLAUDE_FALLO}"
fi

notificar info "Informe del auto-arreglo (${MOTIVO})" \
  "${texto}

--- ${turnos} turnos, USD ${costo}. Salida completa en ${BUNDLE#"${REPO_DIR}/"}/autorepair.json
Revisar los cambios que hayan quedado en la VM con: make remote-diff"
exit "${EXIT_OK}"
