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

log() { echo "update: $*"; }

log "backup antes de tocar nada"
"${REPO_DIR}/scripts/backup.sh" pre-update >/dev/null || log "ADVERTENCIA: el backup fallo"

log "apagado limpio"
"${REPO_DIR}/scripts/stop.sh"

log "docker compose pull"
docker compose pull

log "arrancando con la imagen nueva"
make -C "${REPO_DIR}" up

log "listo. Verificar la version del juego con: make logs | grep -i version"
