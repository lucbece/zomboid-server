#!/usr/bin/env bash
# Prende la VM del server en OCI (Fase 3). Corre en la PC del admin, no en la VM.
#
#   scripts/cloud-start.sh
#   INSTANCE_OCID=ocid1.instance.oc1... scripts/cloud-start.sh
#
# El OCID sale del output de OpenTofu; se puede pisar con la variable de entorno para no
# depender del .tfstate.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

require_oci_cli
ocid="$(oci_instance_ocid)"
echo "cloud-start: START sobre ${ocid}"
oci compute instance action --action START --instance-id "${ocid}" --wait-for-state RUNNING

ip="$(tofu_output public_ip || true)"
if [[ -n "${ip}" ]]; then
  echo "cloud-start: VM prendida. El server tarda ~1 min mas en levantar."
  echo "cloud-start: los amigos se conectan a ${ip}:16261"
else
  echo "cloud-start: VM prendida."
fi
