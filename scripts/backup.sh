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
    -*) die "opcion desconocida: ${arg}" ;;
    *) label="${arg}" ;;
  esac
done
# La etiqueta va en el nombre de archivo: nada de barras ni espacios.
[[ -z "${label}" || "${label}" =~ ^[A-Za-z0-9_-]+$ ]] || die "etiqueta invalida: '${label}'"

if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_DIR}/.env"
  set +a
fi
RCLONE_REMOTE="${RCLONE_REMOTE:-oci}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
BACKUP_KEEP_LOCAL_DAYS="${BACKUP_KEEP_LOCAL_DAYS:-3}"

[[ -d "${DATA_DIR}" ]] || die "no existe ${DATA_DIR}: no hay nada que respaldar"

# --- save por RCON si el server esta corriendo -----------------------------------------------
if docker compose ps -q --status running "${SERVICE}" 2>/dev/null | grep -q .; then
  log "el server esta arriba: pidiendo un save antes de copiar"
  if "${REPO_DIR}/scripts/rcon.sh" save >/dev/null 2>&1; then
    # El save es asincronico: el server sigue escribiendo un rato despues de responder.
    sleep 5
  else
    log "ADVERTENCIA: el save por RCON fallo; se copia igual (puede quedar inconsistente)"
  fi
else
  log "el server no esta corriendo: se copia el estado en disco tal cual"
fi

# --- que se respalda -------------------------------------------------------------------------
# Saves/ = el mundo y los personajes. Server/ = ini + sandbox renderizados. db/ = usuarios y
# whitelist (SQLite). El resto (Logs/, la cache del Workshop) se regenera solo.
targets=()
for rel in "Saves/Multiplayer/servertest" "Server" "db"; do
  if [[ -e "${DATA_DIR}/${rel}" ]]; then
    targets+=("${rel}")
  else
    log "aviso: ${rel} no existe todavia, se omite"
  fi
done
[[ ${#targets[@]} -gt 0 ]] || die "no hay ninguno de Saves/Server/db en ${DATA_DIR}"

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

log "creando ${archive#"${REPO_DIR}/"}"
tar "${compress[@]}" -cf "${archive}.tmp" -C "${DATA_DIR}" "${targets[@]}"
mv "${archive}.tmp" "${archive}"
log "listo: $(du -h "${archive}" | cut -f1)"

# --- upload -----------------------------------------------------------------------------------
if [[ "${upload}" -eq 1 && -n "${BACKUP_BUCKET}" ]] && command -v rclone >/dev/null 2>&1; then
  log "subiendo a ${RCLONE_REMOTE}:${BACKUP_BUCKET}"
  if rclone copy "${archive}" "${RCLONE_REMOTE}:${BACKUP_BUCKET}/"; then
    log "subido"
  else
    log "ADVERTENCIA: rclone fallo. El backup local quedo en ${archive}"
  fi
elif [[ "${upload}" -eq 1 ]]; then
  log "sin BACKUP_BUCKET en .env o sin rclone instalado: solo backup local"
fi

# --- retencion local ---------------------------------------------------------------------------
# En el bucket la retencion la maneja la lifecycle rule de OCI (30 dias por default).
log "borrando backups locales de mas de ${BACKUP_KEEP_LOCAL_DAYS} dias"
find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'zomboid-*.tar.*' \
  -mtime "+${BACKUP_KEEP_LOCAL_DAYS}" -print -delete

echo "${archive}"
