#!/usr/bin/env bash
# Helpers compartidos por cloud-start.sh y cloud-stop.sh. No es ejecutable: se hace source.
#
# Resuelven el OCID de la instancia y su IP publica leyendo los outputs de OpenTofu, con
# override por variable de entorno para no depender del .tfstate local.

TF_ENV_DIR="${TF_ENV_DIR:-${REPO_DIR}/infra/terraform/envs/prod}"

# tofu_output <nombre> [regex] -> imprime el output, o nada si todavia no hay state.
#
# El filtro por regex no es paranoia: sin state, `tofu output` escribe un warning en stdout y
# sale con 0, asi que hay que quedarse solo con la linea que tiene la forma esperada.
tofu_output() {
  local name="$1" pattern="${2:-^.+$}"
  command -v "${TOFU:-tofu}" >/dev/null 2>&1 || return 1
  [[ -d "${TF_ENV_DIR}" ]] || return 1
  "${TOFU:-tofu}" -chdir="${TF_ENV_DIR}" output -raw -no-color "${name}" 2>/dev/null \
    | grep -Eom1 "${pattern}" || true
}

# Patrones de los outputs que se usan mas seguido. Los consumen doctor.sh y deploy.sh, que
# hacen source de este archivo: shellcheck no lo ve y hay que callarle el SC2034.
# shellcheck disable=SC2034
TF_RE_OCID='^ocid1\.[a-z0-9]+\.[A-Za-z0-9._-]+$'
# shellcheck disable=SC2034
TF_RE_IP='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
# shellcheck disable=SC2034
TF_RE_NOMBRE='^[A-Za-z0-9._-]+$'
# shellcheck disable=SC2034
TF_RE_BOOL='^(true|false)$'

oci_instance_ocid() {
  if [[ -n "${INSTANCE_OCID:-}" ]]; then
    echo "${INSTANCE_OCID}"
    return 0
  fi
  local ocid
  if ocid="$(tofu_output instance_ocid "${TF_RE_OCID}")" && [[ -n "${ocid}" ]]; then
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
