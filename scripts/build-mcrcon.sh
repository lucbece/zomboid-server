#!/usr/bin/env bash
# Compila mcrcon en ./bin/mcrcon (gitignoreado) si no esta ya disponible en el sistema.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_DIR}/bin/mcrcon"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

if command -v mcrcon >/dev/null 2>&1; then
  printf '%s\n' "$(t mcrcon.already_path "$(command -v mcrcon)")"
  exit 0
fi
if [[ -x "${BIN}" ]]; then
  printf '%s\n' "$(t mcrcon.already_local "${BIN}")"
  exit 0
fi

command -v gcc >/dev/null 2>&1 || { printf '%s\n' "$(t mcrcon.need_gcc)" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf '%s\n' "$(t mcrcon.need_git)" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
git clone --depth 1 https://github.com/Tiiffi/mcrcon.git "${tmp}/mcrcon"
gcc -std=gnu99 -Wall -pedantic -O2 -s -o "${tmp}/mcrcon/mcrcon" "${tmp}/mcrcon/mcrcon.c"
mkdir -p "${REPO_DIR}/bin"
install -m 755 "${tmp}/mcrcon/mcrcon" "${BIN}"
printf '%s\n' "$(t mcrcon.done "${BIN}")"
