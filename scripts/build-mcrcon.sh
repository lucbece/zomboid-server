#!/usr/bin/env bash
# Compila mcrcon en ./bin/mcrcon (gitignoreado) si no esta ya disponible en el sistema.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_DIR}/bin/mcrcon"

if command -v mcrcon >/dev/null 2>&1; then
  echo "build-mcrcon: ya hay un mcrcon en el PATH ($(command -v mcrcon)), no hace falta compilar"
  exit 0
fi
if [[ -x "${BIN}" ]]; then
  echo "build-mcrcon: ${BIN} ya existe"
  exit 0
fi

command -v gcc >/dev/null 2>&1 || { echo "build-mcrcon: falta gcc (apt install build-essential)" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "build-mcrcon: falta git" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
git clone --depth 1 https://github.com/Tiiffi/mcrcon.git "${tmp}/mcrcon"
gcc -std=gnu99 -Wall -pedantic -O2 -s -o "${tmp}/mcrcon/mcrcon" "${tmp}/mcrcon/mcrcon.c"
mkdir -p "${REPO_DIR}/bin"
install -m 755 "${tmp}/mcrcon/mcrcon" "${BIN}"
echo "build-mcrcon: ${BIN} listo"
