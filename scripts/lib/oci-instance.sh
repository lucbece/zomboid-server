#!/usr/bin/env bash
# Helpers compartidos por cloud-start.sh y cloud-stop.sh. No es ejecutable: se hace source.
#
# Resuelven el OCID de la instancia y su IP publica leyendo los outputs de OpenTofu, con
# override por variable de entorno para no depender del .tfstate local.

TF_ENV_DIR="${TF_ENV_DIR:-${REPO_DIR}/infra/terraform/envs/prod}"

# tofu_output <nombre> -> imprime el output, o falla en silencio si no hay state.
tofu_output() {
  local name="$1"
  command -v tofu >/dev/null 2>&1 || return 1
  [[ -d "${TF_ENV_DIR}" ]] || return 1
  tofu -chdir="${TF_ENV_DIR}" output -raw "${name}" 2>/dev/null
}

oci_instance_ocid() {
  if [[ -n "${INSTANCE_OCID:-}" ]]; then
    echo "${INSTANCE_OCID}"
    return 0
  fi
  local ocid
  if ocid="$(tofu_output instance_ocid)" && [[ -n "${ocid}" ]]; then
    echo "${ocid}"
    return 0
  fi
  echo "oci-instance: ERROR: no se pudo obtener el OCID." >&2
  echo "  Probar: cd infra/terraform/envs/prod && tofu output -raw instance_ocid" >&2
  echo "  O exportar INSTANCE_OCID=ocid1.instance.oc1...." >&2
  return 1
}

require_oci_cli() {
  command -v oci >/dev/null 2>&1 || {
    echo "oci-instance: ERROR: falta el CLI 'oci'. Instalarlo en un venv (ver docs/runbook.md)." >&2
    return 1
  }
}
