#!/usr/bin/env bash
# Reinicio limpio: aviso + save + quit, re-render de la config y arranque.
# Es el camino para aplicar cambios de mods o de servertest.ini.tpl.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

"${REPO_DIR}/scripts/stop.sh"
"${REPO_DIR}/scripts/render-config.sh"
docker compose up -d
echo "restart: server arrancando. Seguir con 'make logs'."
