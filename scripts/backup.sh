#!/usr/bin/env bash
# Backup del mundo: save por RCON (si el server esta arriba), tar comprimido en backups/,
# copia al bucket de Object Storage con rclone y limpieza de los locales viejos.
#
#   scripts/backup.sh                # backup normal
#   scripts/backup.sh pre-wipe       # agrega la etiqueta al nombre del archivo
#   scripts/backup.sh --no-upload    # solo local (util cuando no hay bucket configurado)
#
# Funciona con el server apagado: en ese caso se saltea el save y copia lo que hay en disco.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

SERVICE="zomboid"
DATA_DIR="${REPO_DIR}/data/zomboid"
BACKUP_DIR="${REPO_DIR}/backups"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

log() { echo "backup: $*"; }
die() {
  echo "backup: ERROR: $*" >&2
  exit 1
}

label=""
upload=1
for arg in "$@"; do
  case "${arg}" in
    --no-upload) upload=0 ;;
    -*) die "$(t backup.unknown_option "${arg}")" ;;
    *) label="${arg}" ;;
  esac
done
# La etiqueta va en el nombre de archivo: nada de barras ni espacios.
[[ -z "${label}" || "${label}" =~ ^[A-Za-z0-9_-]+$ ]] || die "$(t backup.bad_label "${label}")"

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_DIR}/.env"
  set +a
fi
RCLONE_REMOTE="${RCLONE_REMOTE:-oci}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
BACKUP_KEEP_LOCAL_DAYS="${BACKUP_KEEP_LOCAL_DAYS:-3}"

[[ -d "${DATA_DIR}" ]] || die "$(t backup.no_data "${DATA_DIR}")"

# --- save por RCON si el server esta corriendo -----------------------------------------------
if docker compose ps -q --status running "${SERVICE}" 2>/dev/null | grep -q .; then
  log "$(t backup.saving)"
  if "${REPO_DIR}/scripts/rcon.sh" save >/dev/null 2>&1; then
    # El save es asincronico: el server sigue escribiendo un rato despues de responder.
    sleep 5
  else
    log "$(t backup.save_failed)"
  fi
else
  log "$(t backup.not_running)"
fi

# --- que se respalda -------------------------------------------------------------------------
# Saves/ = el mundo y los personajes. Server/ = ini + sandbox renderizados. db/ = usuarios y
# whitelist (SQLite). El resto (Logs/, la cache del Workshop) se regenera solo.
targets=()
for rel in "Saves/Multiplayer/servertest" "Server" "db"; do
  if [[ -e "${DATA_DIR}/${rel}" ]]; then
    targets+=("${rel}")
  else
    log "$(t backup.skip_missing "${rel}")"
  fi
done
[[ ${#targets[@]} -gt 0 ]] || die "$(t backup.no_targets "${DATA_DIR}")"

# --- tar --------------------------------------------------------------------------------------
mkdir -p "${BACKUP_DIR}"
stamp="$(date +%Y%m%d-%H%M)"
suffix=""
[[ -n "${label}" ]] && suffix="-${label}"

if command -v zstd >/dev/null 2>&1; then
  archive="${BACKUP_DIR}/zomboid-${stamp}${suffix}.tar.zst"
  compress=(--zstd)
else
  archive="${BACKUP_DIR}/zomboid-${stamp}${suffix}.tar.gz"
  compress=(--gzip)
fi

log "$(t backup.creating "${archive#"${REPO_DIR}/"}")"
tar "${compress[@]}" -cf "${archive}.tmp" -C "${DATA_DIR}" "${targets[@]}"
mv "${archive}.tmp" "${archive}"
log "$(t backup.done "$(du -h "${archive}" | cut -f1)")"

# --- upload -----------------------------------------------------------------------------------
if [[ "${upload}" -eq 1 && -n "${BACKUP_BUCKET}" ]] && command -v rclone >/dev/null 2>&1; then
  log "$(t backup.uploading "${RCLONE_REMOTE}" "${BACKUP_BUCKET}")"
  if rclone copy "${archive}" "${RCLONE_REMOTE}:${BACKUP_BUCKET}/"; then
    log "$(t backup.uploaded)"
  else
    log "$(t backup.upload_failed "${archive}")"
  fi
elif [[ "${upload}" -eq 1 ]]; then
  log "$(t backup.local_only)"
fi

# --- retencion local ---------------------------------------------------------------------------
# En el bucket la retencion la maneja la lifecycle rule de OCI (30 dias por default).
log "$(t backup.pruning "${BACKUP_KEEP_LOCAL_DAYS}")"
find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'zomboid-*.tar.*' \
  -mtime "+${BACKUP_KEEP_LOCAL_DAYS}" -print -delete

echo "${archive}"
