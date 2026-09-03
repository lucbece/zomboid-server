#!/usr/bin/env bash
# Borra el mundo para empezar una partida nueva.
#
#   scripts/wipe.sh          # pide confirmacion escribiendo 'wipe'
#   scripts/wipe.sh --yes    # sin confirmacion (para automatizar)
#
# Hace: apagado limpio -> backup final etiquetado 'pre-wipe' -> borrar Saves/Multiplayer/servertest,
# db/ y los backups nativos del server. NO levanta el server: primero hay que definir
# config/servertest_SandboxVars.lua y config/mods.txt de la partida definitiva.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

DATA_DIR="${REPO_DIR}/data/zomboid"
SAVE_DIR="${DATA_DIR}/Saves/Multiplayer/servertest"

log() { echo "wipe: $*"; }
die() {
  echo "wipe: ERROR: $*" >&2
  exit 1
}

assume_yes=0
for arg in "$@"; do
  case "${arg}" in
    --yes | -y) assume_yes=1 ;;
    *) die "opcion desconocida: ${arg}" ;;
  esac
done

if [[ "${assume_yes}" -ne 1 ]]; then
  cat <<MSG

  WIPE de la partida.

  Se borra:   ${SAVE_DIR}
              ${DATA_DIR}/db
              ${DATA_DIR}/backups (los backups nativos del server)

  Se conserva: un backup final etiquetado 'pre-wipe' en backups/ y en el bucket, y toda la
               config versionada de config/.

  Los personajes de todos los jugadores desaparecen. No se puede deshacer salvo con
  scripts/restore.sh sobre el backup 'pre-wipe'.

MSG
  read -r -p "Escribi 'wipe' para continuar: " answer
  [[ "${answer}" == "wipe" ]] || die "cancelado"
fi

# --- apagado limpio y backup final ----------------------------------------------------------
"${REPO_DIR}/scripts/stop.sh"

if [[ -d "${DATA_DIR}" ]]; then
  log "backup final etiquetado 'pre-wipe'"
  "${REPO_DIR}/scripts/backup.sh" pre-wipe >/dev/null || die "el backup pre-wipe fallo; no se borra nada"
else
  log "no hay ${DATA_DIR}: nada que respaldar"
fi

# --- borrado ----------------------------------------------------------------------------------
for path in "${SAVE_DIR}" "${DATA_DIR}/db" "${DATA_DIR}/backups"; do
  if [[ -e "${path}" ]]; then
    log "borrando ${path#"${REPO_DIR}/"}"
    rm -rf "${path:?}"
  fi
done

cat <<'MSG'

wipe: listo. Antes de arrancar la partida definitiva:

  1. Editar config/servertest_SandboxVars.lua (varias opciones quedan fijadas al crear el mundo).
  2. Editar config/mods.txt (descomentar los mods definitivos).
  3. Revisar config/servertest.ini.tpl (PVP, MaxPlayers, backups).
  4. git commit de esos cambios (en la VM: git pull, o desde la PC: make sync).
  5. make up

MSG
