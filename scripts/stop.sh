#!/usr/bin/env bash
# Apagado limpio del server: aviso por chat, save y quit por RCON, y espera a que el
# contenedor termine de escribir el mundo. Nunca usar 'docker stop'/'docker kill' a secas.
#
#   scripts/stop.sh                 # aviso de 60s antes de guardar
#   WARN_SECONDS=0 scripts/stop.sh  # sin aviso (nadie conectado)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

WARN_SECONDS="${WARN_SECONDS:-60}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"
SERVICE="zomboid"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

log() { echo "stop: $*"; }
rcon() { "${REPO_DIR}/scripts/rcon.sh" "$@"; }

container_id="$(docker compose ps -q "${SERVICE}" 2>/dev/null || true)"
if [[ -z "${container_id}" ]]; then
  log "$(t stop.not_running)"
  exit 0
fi

# El compose usa 'restart: unless-stopped'. Sin desactivarlo, Docker vuelve a levantar el
# server apenas la JVM sale por el 'quit' de RCON y el contenedor nunca termina. Se saca la
# politica en el contenedor vivo; el siguiente 'docker compose up' la restaura desde el yaml.
log "$(t stop.disable_restart)"
docker update --restart=no "${container_id}" >/dev/null

if players_out="$(rcon players 2>/dev/null)"; then
  # Sin jugadores conectados no tiene sentido esperar el aviso.
  if grep -q 'Players connected (0)' <<<"${players_out}"; then
    log "$(t stop.no_players)"
    WARN_SECONDS=0
  fi
  if [[ "${WARN_SECONDS}" -gt 0 ]]; then
    log "$(t stop.warning "${WARN_SECONDS}")"
    rcon "servermsg \"El servidor se apaga en ${WARN_SECONDS} segundos. Ponete a salvo.\"" || true
    sleep "${WARN_SECONDS}"
    rcon "servermsg \"Guardando el mundo y apagando.\"" || true
  fi
  log "$(t stop.save)"
  rcon save || log "$(t stop.save_failed)"
  sleep 5
  log "$(t stop.quit)"
  # 'quit' corta la conexion RCON mientras el server guarda: un error aca es esperable.
  rcon quit || true
else
  log "$(t stop.rcon_down)"
  docker compose stop -t "${SHUTDOWN_TIMEOUT}" "${SERVICE}"
fi

log "$(t stop.waiting "${SHUTDOWN_TIMEOUT}")"
waited=0
while [[ "${waited}" -lt "${SHUTDOWN_TIMEOUT}" ]]; do
  if [[ -z "$(docker compose ps -q --status running "${SERVICE}" 2>/dev/null || true)" ]]; then
    log "$(t stop.exited "${waited}")"
    docker compose down --remove-orphans >/dev/null 2>&1 || true
    log "$(t stop.ok)"
    exit 0
  fi
  sleep 2
  waited=$((waited + 2))
done

log "$(t stop.still_alive "${SHUTDOWN_TIMEOUT}")"
docker compose stop -t 60 "${SERVICE}"
docker compose down --remove-orphans >/dev/null 2>&1 || true
log "$(t stop.forced)"
