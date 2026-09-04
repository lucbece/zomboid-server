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

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

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
    -*) die "$(t restore.unknown_option "${arg}")" ;;
    *) source_arg="${arg}" ;;
  esac
done
[[ -n "${source_arg}" ]] || die "$(t restore.usage "$(basename "$0")")"

# --- resolver el origen -----------------------------------------------------------------------
archive=""
if [[ -f "${source_arg}" ]]; then
  archive="$(cd "$(dirname "${source_arg}")" && pwd)/$(basename "${source_arg}")"
elif [[ "${source_arg}" == *:* ]]; then
  command -v rclone >/dev/null 2>&1 || die "$(t restore.need_rclone "${source_arg}")"
  mkdir -p "${BACKUP_DIR}"
  log "$(t restore.downloading "${source_arg}")"
  rclone copy "${source_arg}" "${BACKUP_DIR}/" --progress
  archive="${BACKUP_DIR}/$(basename "${source_arg}")"
  [[ -f "${archive}" ]] || die "$(t restore.rclone_failed "${archive}")"
else
  die "$(t restore.not_found "${source_arg}")"
fi

tar -tf "${archive}" >/dev/null 2>&1 || die "$(t restore.bad_tar "${archive}")"

# --- confirmacion ------------------------------------------------------------------------------
if [[ "${assume_yes}" -ne 1 ]]; then
  printf '%s\n\n' "$(t restore.warning "${archive}" "${DATA_DIR}")"
  read -r -p "$(t restore.prompt)" answer
  [[ "${answer}" == "restore" ]] || die "$(t restore.cancelled)"
fi

# --- apagado limpio y backup de seguridad -------------------------------------------------------
"${REPO_DIR}/scripts/stop.sh"
if [[ -d "${DATA_DIR}" ]]; then
  log "$(t restore.safety_backup)"
  "${REPO_DIR}/scripts/backup.sh" pre-restore >/dev/null || log "$(t restore.safety_failed)"
fi

# --- extraccion ---------------------------------------------------------------------------------
# Se borran primero los directorios que trae el tar: extraer encima mezclaria archivos de dos
# mundos distintos (chunks huerfanos = corrupcion silenciosa).
mkdir -p "${DATA_DIR}"
for rel in "Saves/Multiplayer/servertest" "db"; do
  if [[ -e "${DATA_DIR}/${rel}" ]] && tar -tf "${archive}" | grep -q "^${rel}"; then
    log "$(t restore.removing "${rel}")"
    rm -rf "${DATA_DIR:?}/${rel}"
  fi
done

log "$(t restore.extracting)"
tar -xf "${archive}" -C "${DATA_DIR}"

# --- arranque ------------------------------------------------------------------------------------
log "$(t restore.starting)"
make -C "${REPO_DIR}" up
log "$(t restore.done)"
