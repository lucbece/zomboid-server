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
# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

require_oci_cli
ocid="$(oci_instance_ocid)"
printf '%s\n' "$(t cloudstart.starting "${ocid}")"
oci compute instance action --action START --instance-id "${ocid}" --wait-for-state RUNNING

ip="$(tofu_output public_ip || true)"
if [[ -n "${ip}" ]]; then
  printf '%s\n' "$(t cloudstart.up_hint)"
  printf '%s\n' "$(t cloudstart.connect "${ip}")"
else
  printf '%s\n' "$(t cloudstart.up)"
fi
