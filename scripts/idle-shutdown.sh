#!/usr/bin/env bash
# Apagado por inactividad (Fase 3). Pensado para correr por cron cada 5 minutos EN LA VM.
#
#   scripts/idle-shutdown.sh
#   IDLE_MINUTES=45 scripts/idle-shutdown.sh
#   DRY_RUN=1 scripts/idle-shutdown.sh   # dice que haria, sin apagar nada
#
# Si hay 0 jugadores durante IDLE_MINUTES seguidos: apagado limpio + backup + shutdown de la VM.
# En OCI una instancia detenida no cobra computo (solo el boot volume), que es de donde sale el
# ahorro del ~85% de la Fase 3.
#
# NO esta en el cron todavia: hasta que exista el bot de Discord que prenda la VM, apagarla
# dejaria a los amigos sin forma de volver a entrar. La linea esta comentada en
# infra/cloud-init.yaml (/etc/cron.d/zomboid).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

SERVICE="zomboid"
# /var/tmp y no /tmp: /tmp se limpia en el boot y el estado tiene que sobrevivir un rato largo.
STATE_FILE="${STATE_FILE:-/var/tmp/zomboid-idle-since}"
DRY_RUN="${DRY_RUN:-0}"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

log() { echo "idle-shutdown: $(date -Is) $*"; }

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_DIR}/.env"
  set +a
fi
IDLE_MINUTES="${IDLE_MINUTES:-30}"

if ! docker compose ps -q --status running "${SERVICE}" 2>/dev/null | grep -q .; then
  log "$(t idle.not_running)"
  rm -f "${STATE_FILE}"
  exit 0
fi

if ! players_out="$("${REPO_DIR}/scripts/rcon.sh" players 2>/dev/null)"; then
  # RCON caido con el contenedor arriba: puede ser que todavia este arrancando. Nunca apagar
  # a ciegas; se reinicia el contador y se reintenta en la proxima corrida.
  log "$(t idle.rcon_down)"
  rm -f "${STATE_FILE}"
  exit 0
fi

if ! grep -q 'Players connected (0)' <<<"${players_out}"; then
  connected="$(grep -oE 'Players connected \([0-9]+\)' <<<"${players_out}" | head -1)"
  log "$(t idle.players "${connected:-?}")"
  rm -f "${STATE_FILE}"
  exit 0
fi

now="$(date +%s)"
if [[ -f "${STATE_FILE}" ]]; then
  since="$(cat "${STATE_FILE}")"
else
  since="${now}"
  echo "${since}" > "${STATE_FILE}"
fi
[[ "${since}" =~ ^[0-9]+$ ]] || { since="${now}"; echo "${since}" > "${STATE_FILE}"; }

idle_secs=$((now - since))
threshold=$((IDLE_MINUTES * 60))
log "$(t idle.idle_for "${idle_secs}" "${threshold}")"

if [[ "${idle_secs}" -lt "${threshold}" ]]; then
  exit 0
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  log "$(t idle.dryrun)"
  exit 0
fi

log "$(t idle.stopping)"
WARN_SECONDS=0 "${REPO_DIR}/scripts/stop.sh"
log "$(t idle.backup)"
"${REPO_DIR}/scripts/backup.sh" idle >/dev/null || log "$(t idle.backup_failed)"
rm -f "${STATE_FILE}"
log "$(t idle.vm_off)"
sudo shutdown -h now
