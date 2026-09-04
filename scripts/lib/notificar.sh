#!/usr/bin/env bash
# Log y notificaciones a Discord, compartidos por scripts/watchdog.sh y scripts/autorepair.sh.
# No es ejecutable: se hace source.
#
# Antes de usarlo:
#   NOTIF_LOG="/var/log/zomboid/watchdog.log"   # a donde va todo (siempre)
#   NOTIF_PREFIJO="watchdog"                    # que nombre aparece en cada linea
#
# El webhook es opcional: sin DISCORD_WEBHOOK_URL en el entorno solo escribe al log. La URL
# del webhook ES una credencial (quien la tenga puede postear en el canal): nunca se imprime.

# shellcheck source=scripts/lib/i18n.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/i18n.sh"

NOTIF_LOG="${NOTIF_LOG:-/var/log/zomboid/notificaciones.log}"
NOTIF_PREFIJO="${NOTIF_PREFIJO:-zomboid}"

log() {
  local linea
  linea="$(date -Is) ${NOTIF_PREFIJO}: $*"
  echo "${linea}"
  # Best-effort: si el log no se puede escribir (permisos, disco lleno) no se aborta la corrida.
  printf '%s\n' "${linea}" >> "${NOTIF_LOG}" 2>/dev/null || true
}

# Colores de los embeds de Discord (decimal, como los espera la API).
notif_color() {
  case "$1" in
    info) echo 3066993 ;;   # verde
    warn) echo 15844367 ;;  # amarillo
    *) echo 15158332 ;;     # rojo
  esac
}

# Arma el JSON del webhook. Con jq si esta (lo instala cloud-init); si no, con python3.
# Se hace con una herramienta y no con printf porque el detalle trae comillas, backslashes y
# saltos de linea del log del juego.
notif_payload() {
  local titulo="$1" descripcion="$2" color="$3"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg t "${titulo}" --arg d "${descripcion}" --argjson c "${color}" \
      '{embeds: [{title: $t, description: $d, color: $c, timestamp: (now | todate)}]}'
  else
    python3 -c '
import datetime, json, sys
titulo, descripcion, color = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({"embeds": [{
    "title": titulo,
    "description": descripcion,
    "color": color,
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}]}))' "${titulo}" "${descripcion}" "${color}"
  fi
}

# notificar <info|warn|error> <titulo> [detalle]
notificar() {
  local nivel="$1" titulo="$2" detalle="${3:-}"
  log "[${nivel^^}] ${titulo}"
  if [[ -n "${detalle}" ]]; then
    printf '%s\n' "${detalle}" | sed 's/^/    /' >> "${NOTIF_LOG}" 2>/dev/null || true
  fi

  [[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || return 0

  # Del detalle solo van las primeras 25 lineas recortadas a 140 columnas: es lo que alcanza
  # para decidir si hay que entrar a mirar, y ademas la descripcion de un embed tiene un
  # limite duro de 4096 caracteres.
  local cuerpo="" descripcion="**${PUBLIC_NAME:-${NOTIF_PREFIJO}}**"
  if [[ -n "${detalle}" ]]; then
    cuerpo="$(printf '%s\n' "${detalle}" | head -n 25 | cut -c1-140)"
    descripcion="${descripcion}"$'\n```\n'"${cuerpo}"$'\n```'
  fi
  descripcion="${descripcion:0:3900}"

  local json
  if ! json="$(notif_payload "${titulo}" "${descripcion}" "$(notif_color "${nivel}")")"; then
    log "$(t notif.json.fail)"
    return 0
  fi
  if ! printf '%s' "${json}" | curl -fsS -m 15 -X POST \
      -H 'Content-Type: application/json' --data-binary @- \
      "${DISCORD_WEBHOOK_URL}" >/dev/null; then
    log "$(t notif.post.fail)"
  fi
}
