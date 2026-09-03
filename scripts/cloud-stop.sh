#!/usr/bin/env bash
# Apaga la VM del server en OCI (Fase 3). Corre en la PC del admin, no en la VM.
#
#   scripts/cloud-stop.sh
#   scripts/cloud-stop.sh --hard    # sin apagado limpio previo por SSH (solo si el SSH murio)
#
# Por default primero entra por SSH y corre stop.sh + backup.sh, y recien despues manda el
# SOFTSTOP. El SOFTSTOP de OCI dispara el shutdown del SO, que a su vez dispara el ExecStop de
# zomboid.service (que tambien hace save + quit): el paso por SSH es cinturon y tiradores, y
# ademas deja el backup subido antes de apagar.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

hard=0
for arg in "$@"; do
  case "${arg}" in
    --hard) hard=1 ;;
    *) echo "cloud-stop: opcion desconocida: ${arg}" >&2; exit 1 ;;
  esac
done

require_oci_cli
ocid="$(oci_instance_ocid)"

if [[ "${hard}" -eq 0 ]]; then
  ip="$(tofu_output public_ip || true)"
  user="${VM_USER:-pz}"
  if [[ -n "${ip}" ]]; then
    echo "cloud-stop: apagado limpio del server en ${user}@${ip}"
    ssh -o ConnectTimeout=10 "${user}@${ip}" \
      'cd /opt/zomboid-server && ./scripts/stop.sh && ./scripts/backup.sh' \
      || echo "cloud-stop: ADVERTENCIA: el apagado por SSH fallo; el SOFTSTOP igual dispara el ExecStop del systemd"
  else
    echo "cloud-stop: ADVERTENCIA: no se pudo resolver la IP; se va derecho al SOFTSTOP"
  fi
fi

echo "cloud-stop: SOFTSTOP sobre ${ocid}"
oci compute instance action --action SOFTSTOP --instance-id "${ocid}" --wait-for-state STOPPED
echo "cloud-stop: VM detenida. OCI no cobra computo con la instancia en STOPPED."
