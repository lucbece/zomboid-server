#!/usr/bin/env bash
# Actualiza la imagen del server con un apagado limpio de por medio.
#
#   scripts/update.sh
#
# La imagen esta pinneada por digest en docker-compose.yml, asi que este script SOLO cambia
# algo si antes se edito ese digest. Para actualizar a la ultima imagen publicada:
#
#   docker pull danixu86/project-zomboid-dedicated-server:latest
#   docker image inspect danixu86/project-zomboid-dedicated-server:latest \
#     --format '{{index .RepoDigests 0}}'
#   # copiar ese sha256:... al campo `image:` de docker-compose.yml, commitear, y correr esto.
#
# Ojo: una imagen nueva puede traer una version del juego nueva. Si los clientes ven
# "server has different version", tienen que actualizar el cliente en Steam (o hay que volver
# al digest anterior). Ver docs/runbook.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

log() { echo "update: $*"; }

log "$(t update.backup)"
"${REPO_DIR}/scripts/backup.sh" pre-update >/dev/null || log "$(t update.backup_failed)"

log "$(t update.stopping)"
"${REPO_DIR}/scripts/stop.sh"

log "$(t update.pulling)"
docker compose pull

log "$(t update.starting)"
make -C "${REPO_DIR}" up

log "$(t update.done)"
