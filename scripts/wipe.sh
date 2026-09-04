#!/usr/bin/env bash
# Borra el mundo para empezar una partida nueva.
#
#   scripts/wipe.sh          # pide confirmacion escribiendo 'wipe'
#   scripts/wipe.sh --yes    # sin confirmacion (para automatizar)
#
# Hace: apagado limpio -> backup final etiquetado 'pre-wipe' -> borrar Saves/Multiplayer/servertest,
# db/ y los backups nativos del server. NO levanta el server: primero hay que definir
# config/servertest_SandboxVars.lua y config/mods.txt (no versionado; sin el, vanilla) de la
# partida definitiva.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

DATA_DIR="${REPO_DIR}/data/zomboid"
SAVE_DIR="${DATA_DIR}/Saves/Multiplayer/servertest"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

log() { echo "wipe: $*"; }
die() {
  echo "wipe: ERROR: $*" >&2
  exit 1
}

assume_yes=0
for arg in "$@"; do
  case "${arg}" in
    --yes | -y) assume_yes=1 ;;
    *) die "$(t wipe.unknown_option "${arg}")" ;;
  esac
done

if [[ "${assume_yes}" -ne 1 ]]; then
  printf '%s\n\n' "$(t wipe.warning "${SAVE_DIR}" "${DATA_DIR}" "${DATA_DIR}")"
  read -r -p "$(t wipe.prompt)" answer
  [[ "${answer}" == "wipe" ]] || die "$(t wipe.cancelled)"
fi

# --- apagado limpio y backup final ----------------------------------------------------------
"${REPO_DIR}/scripts/stop.sh"

if [[ -d "${DATA_DIR}" ]]; then
  log "$(t wipe.backup)"
  "${REPO_DIR}/scripts/backup.sh" pre-wipe >/dev/null || die "$(t wipe.backup_failed)"
else
  log "$(t wipe.no_data "${DATA_DIR}")"
fi

# --- borrado ----------------------------------------------------------------------------------
for path in "${SAVE_DIR}" "${DATA_DIR}/db" "${DATA_DIR}/backups"; do
  if [[ -e "${path}" ]]; then
    log "$(t wipe.deleting "${path#"${REPO_DIR}/"}")"
    rm -rf "${path:?}"
  fi
done

printf '%s\n\n' "$(t wipe.done)"
