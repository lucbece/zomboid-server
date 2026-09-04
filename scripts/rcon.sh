#!/usr/bin/env bash
# Wrapper de mcrcon contra el server local. Lee la password de .env.
#
#   scripts/rcon.sh players
#   scripts/rcon.sh 'servermsg "hola"'
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

die() {
  echo "rcon: ERROR: $*" >&2
  exit 1
}

[[ -f "${ENV_FILE}" ]] || die "$(t rcon.no_env "${ENV_FILE}")"
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

[[ -n "${RCONPASSWORD:-}" ]] || die "$(t rcon.no_password)"
RCON_HOST="${RCON_HOST:-127.0.0.1}"
RCON_PORT="${RCON_PORT:-27015}"

# mcrcon: primero el binario local compilado, despues el del PATH.
if [[ -x "${REPO_DIR}/bin/mcrcon" ]]; then
  MCRCON="${REPO_DIR}/bin/mcrcon"
elif command -v mcrcon >/dev/null 2>&1; then
  MCRCON="$(command -v mcrcon)"
else
  die "$(t rcon.no_mcrcon)"
fi

[[ $# -gt 0 ]] || die "$(t rcon.usage "$(basename "$0")")"

# Quirk verificado en 42.20.4: el server responde un paquete "tarde" — mcrcon no ve la
# respuesta del comando N hasta que manda el N+1, asi que en modo no interactivo un solo
# comando no imprime nada. Se agrega un `players` de descarte al final para vaciar la cola;
# su propia respuesta es la que se pierde. Ver docs/mods.md.
exec "${MCRCON}" -H "${RCON_HOST}" -P "${RCON_PORT}" -p "${RCONPASSWORD}" "$@" players
