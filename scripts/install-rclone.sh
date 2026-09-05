#!/usr/bin/env bash
# Instala rclone desde downloads.rclone.org, con version y checksum fijos.
#
#   sudo scripts/install-rclone.sh
#
# Por que no el paquete de apt: Ubuntu 24.04 trae rclone 1.60, que no tiene el backend
# `oracleobjectstorage` (llego en 1.62). Con ese rclone, backup.sh falla con "didn't find
# backend called oracleobjectstorage" y el bucket queda vacio sin que nadie lo note.
# Idempotente: si ya esta la version pedida, no baja nada.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

RCLONE_VERSION="${RCLONE_VERSION:-v1.75.1}"
RCLONE_SHA256="${RCLONE_SHA256:-09c9f7606ed9e31eecc1eec26a89992cf2931a8d2d1a5f0ae2bb1c11630ffb15}"
DEB="rclone-${RCLONE_VERSION}-linux-amd64.deb"
URL="https://downloads.rclone.org/${RCLONE_VERSION}/${DEB}"

if command -v rclone >/dev/null 2>&1 && rclone version 2>/dev/null | head -1 | grep -q "rclone ${RCLONE_VERSION}"; then
  t rclone.already "${RCLONE_VERSION}"; echo
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || { t rclone.need_root; echo; exit 1; } >&2

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
t rclone.downloading "${URL}"; echo
curl -fsSL --retry 3 -o "${tmp}/${DEB}" "${URL}"
echo "${RCLONE_SHA256}  ${tmp}/${DEB}" | sha256sum -c --quiet
# El paquete de apt (si quedo de una instalacion vieja) se pisa con la version pinneada.
dpkg -i "${tmp}/${DEB}" >/dev/null
t rclone.installed "$(rclone version | head -1)"; echo
