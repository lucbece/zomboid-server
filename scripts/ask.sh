#!/usr/bin/env bash
# La otra puerta a la misma persona que arregla el server sola de madrugada.
#
# El watchdog abre esa puerta cuando el server se cae (scripts/autorepair.sh). Esta la abre el
# bot de Discord cuando alguien pregunta algo en voz alta en la llamada. Mismo repo, mismas
# reglas duras (tools/autorepair/CLAUDE.md), misma lista blanca de herramientas; lo que cambia
# es que hay una persona despierta esperando la respuesta, y eso esta escrito en
# tools/ask/CLAUDE.md.
#
#   echo "por que se cayo hoy a la tarde?" | scripts/ask.sh --read
#   scripts/ask.sh --pregunta "reinicia el server" --completo
#   DRY_RUN=1 scripts/ask.sh --read --pregunta "hola"   # imprime el plan, sin llamar a Claude
#
# La pregunta entra por stdin a proposito: la clave SSH del bot esta atada a este script con
# command= en authorized_keys, y stdin es el unico canal que no depende de como el cliente
# arme la linea de comandos.
#
# Escribe UNA linea de JSON en stdout, siempre, pase lo que pase:
#
#   {"ok":true,"spoken":"...","detail":"...","turns":7,"cost":"0.03"}
#   {"ok":false,"error":"sin cupo","spoken":"..."}
#
# Nada mas sale por stdout: los logs van al archivo de siempre y a stderr. Del otro lado hay un
# bot que va a decir `spoken` en voz alta.
set -euo pipefail

REPO_DIR="${ASK_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${REPO_DIR}"

STATE_DIR="${ASK_STATE_DIR:-/var/tmp/zomboid-ask}"
LOG_FILE="${ASK_LOG:-/var/log/zomboid/ask.log}"
DRY_RUN="${DRY_RUN:-0}"

MODO="lectura"
PREGUNTA=""

uso() {
  printf 'uso: %s [--read|--completo] [--pregunta "..."]  (si no, la pregunta entra por stdin)\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --read | --lectura) MODO="lectura"; shift ;;
    --completo | --full) MODO="completo"; shift ;;
    --pregunta) PREGUNTA="${2:-}"; shift 2 ;;
    -h | --help) uso; exit 0 ;;
    *) uso >&2; printf 'opcion desconocida: %s\n' "$1" >&2; exit 2 ;;
  esac
done

mkdir -p "${STATE_DIR}" 2>/dev/null || true
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

registrar() {
  printf '%s  %s\n' "$(date '+%F %T')" "$1" >> "${LOG_FILE}" 2>/dev/null || true
  printf '%s\n' "$1" >&2
}

# Una sola linea de JSON en stdout, y se termina. Es la unica forma de salir de este script:
# del otro lado hay un bot que tiene que decir algo, y "nada" no es una respuesta.
responder() {
  local ok="$1" spoken="$2" detail="${3:-}" extra="${4:-}"
  ok="${ok}" spoken="${spoken}" detail="${detail}" extra="${extra}" python3 - <<'PY'
import json, os
out = {"ok": os.environ["ok"] == "1", "spoken": os.environ["spoken"]}
if os.environ.get("detail"):
    out["detail"] = os.environ["detail"]
if os.environ.get("extra"):
    try:
        out.update(json.loads(os.environ["extra"]))
    except json.JSONDecodeError:
        pass
print(json.dumps(out, ensure_ascii=False))
PY
}

if [[ -z "${PREGUNTA}" ]]; then
  PREGUNTA="$(cat)"
fi
PREGUNTA="$(printf '%s' "${PREGUNTA}" | tr -d '\000' | head -c 2000)"

if [[ -z "${PREGUNTA//[[:space:]]/}" ]]; then
  responder 0 "No me llegó ninguna pregunta." "" '{"error":"pregunta vacia"}'
  exit 0
fi

# Del .env se leen solo las claves que este script necesita, y se exportan una por una.
# `set -a; source .env` metia el archivo entero — password de admin, de RCON, del server, token
# de Discord, webhook — en el ambiente del proceso `claude`, donde queda alcanzable desde
# cualquier comando que imprima el entorno. La credencial de Anthropic tiene que estar ahi; el
# resto no tiene por que.
while IFS='=' read -r clave valor; do
  [[ -n "${clave}" ]] && export "${clave}=${valor}"
done < <(
  if [[ -f "${REPO_DIR}/.env" ]]; then
    (
      set -a
      # shellcheck source=/dev/null
      source "${REPO_DIR}/.env"
      set +a
      for clave in CLAUDE_ASK ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN \
        ASK_MAX_PER_DAY ASK_MAX_PER_HOUR ASK_MAX_TURNS ASK_TIMEOUT ASK_MODEL ASK_PERMISSION_MODE; do
        [[ -n "${!clave-}" ]] && printf '%s=%s\n' "${clave}" "${!clave}"
      done
    )
  fi
)

MAX_POR_DIA="${ASK_MAX_PER_DAY:-40}"
MAX_POR_HORA="${ASK_MAX_PER_HOUR:-15}"
MAX_TURNS="${ASK_MAX_TURNS:-12}"
TIMEOUT="${ASK_TIMEOUT:-5m}"
MODELO="${ASK_MODEL:-}"

# --- Guardas ----------------------------------------------------------------------------------

# Deliberadamente separada de CLAUDE_AUTOREPAIR: dejar que el watchdog arregle solo de
# madrugada y dejar que cualquiera pregunte por voz son dos decisiones distintas.
if [[ "${CLAUDE_ASK:-0}" != "1" ]]; then
  registrar "CLAUDE_ASK no esta en 1: la puerta esta cerrada"
  responder 0 "La puerta de preguntas está cerrada en el server." "" '{"error":"deshabilitado"}'
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  registrar "el CLI 'claude' no esta instalado en la VM"
  responder 0 "No tengo con qué contestar: falta instalar el CLI en la VM." "" '{"error":"sin cli"}'
  exit 0
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  registrar "no hay credencial (ANTHROPIC_API_KEY ni CLAUDE_CODE_OAUTH_TOKEN)"
  responder 0 "No tengo credencial para pensar en la VM." "" '{"error":"sin credencial"}'
  exit 0
fi

# Cupo propio, separado del auto-arreglo. Una pregunta hablada cuesta plata y hay una sala
# entera que puede hacerlas de a una por segundo.
MARCAS="${STATE_DIR}/invocaciones"
contar_desde() {
  local corte ts n=0
  corte=$(( $(date +%s) - $1 ))
  [[ -f "${MARCAS}" ]] || { echo 0; return 0; }
  while IFS=$'\t' read -r ts _; do
    [[ "${ts}" =~ ^[0-9]+$ ]] && (( ts >= corte )) && n=$(( n + 1 ))
  done < "${MARCAS}"
  echo "${n}"
}

# Leer el contador y anexar la marca tienen que ser una sola cosa: con una sala preguntando a
# la vez, dos invocaciones leen el contador antes de que cualquiera escriba, y el cupo no
# cuenta nada. De paso se podan las marcas de mas de un dia, que si no crecen para siempre.
exec 9>"${STATE_DIR}/cupo.lock"
flock 9 2>/dev/null || true

if [[ -s "${MARCAS}" ]]; then
  corte_dia=$(( $(date +%s) - 86400 ))
  if awk -F'\t' -v corte="${corte_dia}" '$1 ~ /^[0-9]+$/ && $1 >= corte' "${MARCAS}" > "${MARCAS}.tmp"; then
    mv "${MARCAS}.tmp" "${MARCAS}"
  else
    rm -f "${MARCAS}.tmp"
  fi
fi

en_hora="$(contar_desde 3600)"
en_dia="$(contar_desde 86400)"
if (( en_hora >= MAX_POR_HORA )) || (( en_dia >= MAX_POR_DIA )); then
  registrar "sin cupo (${en_hora}/${MAX_POR_HORA} por hora, ${en_dia}/${MAX_POR_DIA} por dia)"
  responder 0 "Ya me preguntaron demasiado por hoy, esperá un rato." "" '{"error":"sin cupo"}'
  exit 0
fi

# --- Prompt y herramientas --------------------------------------------------------------------

PLANTILLA="${REPO_DIR}/tools/ask/prompt.md"
REGLAS_BASE="${REPO_DIR}/tools/autorepair/CLAUDE.md"
REGLAS_ASK="${REPO_DIR}/tools/ask/CLAUDE.md"
for f in "${PLANTILLA}" "${REGLAS_BASE}" "${REGLAS_ASK}"; do
  [[ -f "$f" ]] || { registrar "falta ${f}"; responder 0 "Me falta un archivo en la VM para poder contestar." "" '{"error":"falta archivo"}'; exit 0; }
done

render() {
  awk -v pregunta="${PREGUNTA}" -v modo="${MODO}" '
    { gsub(/\{\{PREGUNTA\}\}/, pregunta); gsub(/\{\{MODO\}\}/, modo); print }' "${PLANTILLA}"
}
PROMPT="$(render)"

# En lectura no hay una sola herramienta que cambie nada: ni Edit, ni restart, ni stop, ni
# backup, y de rcon solo `players`. Es la segunda cerradura de la misma puerta — el bot ya
# decide segun el rol de quien pregunta, y esto no depende de que el bot lo haga bien.
#
# Y son comandos concretos, no `cat:*` ni `grep:*`. Una lista blanca no sabe decir "cat menos
# el .env": `Bash(cat:*)` matchea `cat .env`, y el .env de esta VM tiene el password de admin,
# el de RCON, el del server y el token de Discord. El destino de esta salida no es un log: es
# una voz en una llamada y un mensaje en un canal. Para leer archivos estan Read/Grep/Glob, que
# no salen del directorio de trabajo y que el deny de abajo acota.
#
# `docker compose logs` va con --tail obligatorio: `make logs` es `logs -f` y se colgaria hasta
# el timeout, que del otro lado son cinco minutos de silencio esperando un error.
HERRAMIENTAS_LECTURA="${ASK_READ_TOOLS:-Bash(make status:*),Bash(make doctor:*),Bash(docker compose ps:*),Bash(docker compose logs --tail:*),Bash(./scripts/rcon.sh players),Bash(df:*),Bash(free:*),Bash(uptime:*),Read,Grep,Glob}"
HERRAMIENTAS_COMPLETO="${ASK_FULL_TOOLS:-${HERRAMIENTAS_LECTURA},Bash(make up:*),Bash(make down:*),Bash(make restart:*),Bash(make render:*),Bash(./scripts/rcon.sh:*),Bash(./scripts/restart.sh:*),Bash(./scripts/stop.sh:*),Bash(./scripts/backup.sh:*),Edit}"

# Lo que no se puede tocar en ningun modo. Redundante con la lista blanca a proposito: la
# blanca dice que se puede correr y esta dice que no se puede leer, y el .env es un archivo
# adentro del repo, o sea adentro del directorio de trabajo.
PROHIBIDO="${ASK_DENIED_TOOLS:-Read(./.env),Read(.env),Read(./.env.*),Bash(cat:*),Bash(grep:*),Bash(tail:*),Bash(head:*),Bash(env:*),Bash(printenv:*),Bash(sudo:*),Bash(docker exec:*),Bash(ssh:*),Bash(curl:*),Bash(wget:*)}"

if [[ "${MODO}" == "completo" ]]; then
  HERRAMIENTAS="${HERRAMIENTAS_COMPLETO}"
  MODO_PERMISOS="${ASK_PERMISSION_MODE:-acceptEdits}"
else
  HERRAMIENTAS="${HERRAMIENTAS_LECTURA}"
  # Nada que aceptar: en lectura no hay ninguna herramienta que escriba.
  MODO_PERMISOS="${ASK_PERMISSION_MODE:-dontAsk}"
fi

SALIDA="${STATE_DIR}/ultima.json"

cmd=(timeout "${TIMEOUT}" claude -p "${PROMPT}"
     --output-format json
     --max-turns "${MAX_TURNS}"
     --permission-mode "${MODO_PERMISOS}"
     --allowedTools "${HERRAMIENTAS}"
     --disallowedTools "${PROHIBIDO}"
     --append-system-prompt "$(cat "${REGLAS_BASE}"; printf '\n\n'; cat "${REGLAS_ASK}")")
[[ -n "${MODELO}" ]] && cmd+=(--model "${MODELO}")

if [[ "${DRY_RUN}" == "1" ]]; then
  registrar "dry run: modo=${MODO} turnos=${MAX_TURNS} timeout=${TIMEOUT} permisos=${MODO_PERMISOS}"
  responder 1 "Dry run." "modo: ${MODO}
herramientas: ${HERRAMIENTAS}
pregunta: ${PREGUNTA}"
  exit 0
fi

# --- Invocacion -------------------------------------------------------------------------------

printf '%s\t%s\n' "$(date +%s)" "${MODO}" >> "${MARCAS}"
# Contado ya, y el candado se suelta: la llamada tarda minutos y nadie mas puede esperarla.
exec 9>&-
registrar "preguntando (${MODO}): ${PREGUNTA:0:120}"

rc=0
"${cmd[@]}" > "${SALIDA}" 2>>"${LOG_FILE}" || rc=$?

if (( rc != 0 )) || [[ ! -s "${SALIDA}" ]]; then
  # La ultima linea del log va en el detalle: un flag que esta version del CLI no acepta y un
  # modelo que fallo suenan igual desde afuera — "me quedé sin poder contestar" — y son
  # problemas completamente distintos.
  motivo="$(tail -n 1 "${LOG_FILE}" 2>/dev/null || true)"
  registrar "claude salio con codigo ${rc}"
  responder 0 "Me quedé sin poder contestar eso." "El proceso terminó con código ${rc}.
${motivo}" "$(printf '{"error":"claude rc %s"}' "${rc}")"
  exit 0
fi

# El informe util es `result`. El bloque JSON que pedimos esta al final de ese texto; si no
# vino, lo de siempre: el texto entero es el detalle y la primera frase es lo que se dice.
SALIDA="${SALIDA}" python3 - <<'PY'
import json, os, re

raw = json.load(open(os.environ["SALIDA"]))
text = (raw.get("result") or "").strip()
out = {"ok": not raw.get("is_error", False), "turns": raw.get("num_turns"), "cost": raw.get("total_cost_usd")}

bloque = None
for m in re.finditer(r"\{[^{}]*\"spoken\"[^{}]*\}", text, re.S):
    bloque = m.group(0)
if bloque:
    try:
        parsed = json.loads(bloque)
        out["spoken"] = str(parsed.get("spoken", "")).strip()
        out["detail"] = str(parsed.get("detail", "")).strip()
        text = text[: text.rindex(bloque)].strip()
    except json.JSONDecodeError:
        bloque = None

if not out.get("spoken"):
    # Sin el bloque: la primera frase es lo que se dice y el resto queda escrito. Peor que el
    # contrato, mucho mejor que el silencio.
    primera = re.split(r"(?<=[.!?])\s", text.replace("\n", " ").strip(), maxsplit=1)
    out["spoken"] = (primera[0] if primera else "").strip()[:300] or "Miré, pero no me salió un resumen corto."
    out["detail"] = text
elif text and not out.get("detail"):
    out["detail"] = text

print(json.dumps(out, ensure_ascii=False))
PY
