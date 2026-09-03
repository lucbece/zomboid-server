#!/usr/bin/env bash
# Restaura un backup creado por scripts/backup.sh.
#
#   scripts/restore.sh backups/zomboid-20260903-0600.tar.zst
#   scripts/restore.sh oci:zomboid-backups/zomboid-20260903-0600.tar.zst
#   scripts/restore.sh --yes backups/zomboid-20260903-0600.tar.zst
#
# Hace: confirmacion -> apagado limpio -> backup de seguridad de lo actual -> extraccion -> make up.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

DATA_DIR="${REPO_DIR}/data/zomboid"
BACKUP_DIR="${REPO_DIR}/backups"

log() { echo "restore: $*"; }
die() {
  echo "restore: ERROR: $*" >&2
  exit 1
}

assume_yes=0
source_arg=""
for arg in "$@"; do
  case "${arg}" in
    --yes | -y) assume_yes=1 ;;
    -*) die "opcion desconocida: ${arg}" ;;
    *) source_arg="${arg}" ;;
  esac
done
[[ -n "${source_arg}" ]] || die "uso: $(basename "$0") [--yes] <archivo|remoto:bucket/nombre>"

# --- resolver el origen -----------------------------------------------------------------------
archive=""
if [[ -f "${source_arg}" ]]; then
  archive="$(cd "$(dirname "${source_arg}")" && pwd)/$(basename "${source_arg}")"
elif [[ "${source_arg}" == *:* ]]; then
  command -v rclone >/dev/null 2>&1 || die "hace falta rclone para bajar '${source_arg}'"
  mkdir -p "${BACKUP_DIR}"
  log "bajando ${source_arg}"
  rclone copy "${source_arg}" "${BACKUP_DIR}/" --progress
  archive="${BACKUP_DIR}/$(basename "${source_arg}")"
  [[ -f "${archive}" ]] || die "rclone no dejo ${archive}"
else
  die "no existe '${source_arg}' y no parece un remoto de rclone (falta 'remoto:')"
fi

tar -tf "${archive}" >/dev/null 2>&1 || die "${archive} no es un tar valido o falta el compresor"

# --- confirmacion ------------------------------------------------------------------------------
if [[ "${assume_yes}" -ne 1 ]]; then
  cat <<MSG

  Se va a RESTAURAR:  ${archive}
  Sobre:              ${DATA_DIR}

  Esto apaga el server, borra el mundo actual (Saves/Multiplayer/servertest y db/) y lo
  reemplaza por el del backup. Antes se guarda un backup de seguridad etiquetado 'pre-restore'.

MSG
  read -r -p "Escribi 'restore' para continuar: " answer
  [[ "${answer}" == "restore" ]] || die "cancelado"
fi

# --- apagado limpio y backup de seguridad -------------------------------------------------------
"${REPO_DIR}/scripts/stop.sh"
if [[ -d "${DATA_DIR}" ]]; then
  log "backup de seguridad del estado actual"
  "${REPO_DIR}/scripts/backup.sh" pre-restore >/dev/null || log "ADVERTENCIA: el backup de seguridad fallo"
fi

# --- extraccion ---------------------------------------------------------------------------------
# Se borran primero los directorios que trae el tar: extraer encima mezclaria archivos de dos
# mundos distintos (chunks huerfanos = corrupcion silenciosa).
mkdir -p "${DATA_DIR}"
for rel in "Saves/Multiplayer/servertest" "db"; do
  if [[ -e "${DATA_DIR}/${rel}" ]] && tar -tf "${archive}" | grep -q "^${rel}"; then
    log "borrando ${rel} actual"
    rm -rf "${DATA_DIR:?}/${rel}"
  fi
done

log "extrayendo"
tar -xf "${archive}" -C "${DATA_DIR}"

# --- arranque ------------------------------------------------------------------------------------
log "levantando el server"
make -C "${REPO_DIR}" up
log "listo. Seguir el arranque con 'make logs'."
