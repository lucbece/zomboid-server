#!/usr/bin/env bash
# Revisa que esté todo listo para desplegar y operar el server, y explica en una línea qué
# hacer con cada cosa que falta.
#
#   make doctor            # revisión completa
#   scripts/doctor.sh -q   # solo lo que está mal (lo usa scripts/deploy.sh antes de arrancar)
#
# Códigos de salida:
#   0  todo lo bloqueante está en orden (puede haber AVISOs)
#   1  falta algo sin lo cual `make deploy` no puede funcionar
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/ui.sh
source "${REPO_DIR}/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

TF_DIR="${TF_ENV_DIR}"
TFVARS="${TF_DIR}/terraform.tfvars"
ENV_FILE="${REPO_DIR}/.env"
OCI_CONFIG="${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}"
TOFU="${TOFU:-tofu}"

QUIET=0
for arg in "$@"; do
  case "${arg}" in
    -q | --quiet) QUIET=1 ;;
    -h | --help | --ayuda)
      printf '%s\n' "$(t doctor.help)"
      exit 0
      ;;
    *) ui_die "$(t doctor.unknown_option "${arg}")" ;;
  esac
done

export PATH="${HOME}/.local/bin:${PATH}"

PROBLEMAS=0

# En modo -q solo se imprimen los AVISO y los FALTA (con su linea de accion): los OK se callan,
# y las lineas de accion que cuelgan de un OK tambien.
ULTIMO_FUE_OK=0
say_title() { [[ "${QUIET}" -eq 1 ]] || ui_title "$@"; }
say_ok() {
  ULTIMO_FUE_OK=1
  [[ "${QUIET}" -eq 1 ]] || ui_ok "$@"
}
say_warn() {
  ULTIMO_FUE_OK=0
  ui_warn "$@"
}
say_miss() {
  ULTIMO_FUE_OK=0
  ui_miss "$@"
  PROBLEMAS=$((PROBLEMAS + 1))
}
say_hint() {
  [[ "${QUIET}" -eq 1 && "${ULTIMO_FUE_OK}" -eq 1 ]] && return 0
  ui_hint "$@"
}

# Lee un valor de terraform.tfvars.
tfvar() {
  [[ -f "${TFVARS}" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" \
    "${TFVARS}" | head -1
}

[[ "${QUIET}" -eq 1 ]] || printf '%s\n' "$(t doctor.header)"

# =============================================================================================
# 1. Programas
# =============================================================================================

say_title "$(t doctor.title.1)"

if ((BASH_VERSINFO[0] >= 4)); then
  say_ok "bash ${BASH_VERSION%%(*}"
else
  say_miss "$(t doctor.bash.old "${BASH_VERSION%%(*}")"
  say_hint "$(t doctor.bash.macos)"
fi

for cmd in git curl make ssh rsync; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    say_ok "${cmd}"
  else
    say_miss "$(t doctor.cmd.missing "${cmd}")"
    say_hint "$(t doctor.cmd.hint "${cmd}")"
  fi
done

if command -v "${TOFU}" >/dev/null 2>&1; then
  say_ok "$(t doctor.tofu.ok "$("${TOFU}" version | head -1 | awk '{print $2}')")"
else
  say_miss "$(t doctor.tofu.missing)"
  say_hint "$(t doctor.tofu.hint)"
fi

# Clave SSH: sin ella no se puede entrar a la máquina.
ssh_pub=""
for f in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_ecdsa.pub" "${HOME}/.ssh/id_rsa.pub"; do
  [[ -f "${f}" ]] && {
    ssh_pub="${f}"
    break
  }
done
if [[ -n "${ssh_pub}" ]]; then
  say_ok "$(t doctor.ssh.ok "${ssh_pub}")"
else
  say_miss "$(t doctor.ssh.missing)"
  say_hint "$(t doctor.ssh.hint)"
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  say_ok "$(t doctor.gh.ok)"
else
  say_warn "$(t doctor.gh.missing)"
  say_hint "$(t doctor.gh.hint)"
fi

# =============================================================================================
# 2. Cuenta de Oracle Cloud
# =============================================================================================

say_title "$(t doctor.title.2)"

oci_ok=0
if [[ -f "${OCI_CONFIG}" ]]; then
  if grep -qE '^\[DEFAULT\]' "${OCI_CONFIG}"; then
    say_ok "$(t doctor.oci.profile_ok "${OCI_CONFIG}")"
  else
    say_miss "$(t doctor.oci.profile_missing "${OCI_CONFIG}")"
    say_hint "$(t doctor.oci.profile_hint)"
  fi

  key_file="$(sed -n -E 's/^[[:space:]]*key_file[[:space:]]*=[[:space:]]*(.*)$/\1/p' "${OCI_CONFIG}" | head -1)"
  key_file="${key_file/#\~/${HOME}}"
  if [[ -n "${key_file}" && -f "${key_file}" ]]; then
    say_ok "$(t doctor.oci.key_ok "${key_file}")"
  else
    say_miss "$(t doctor.oci.key_missing "${OCI_CONFIG}")"
    say_hint "$(t doctor.oci.key_hint "${HOME}/.oci/oci_api_key.pem")"
  fi
else
  say_miss "$(t doctor.oci.config_missing "${OCI_CONFIG}")"
  say_hint "$(t doctor.oci.config_hint)"
fi

if command -v oci >/dev/null 2>&1; then
  say_ok "$(t doctor.oci.cli_ok)"
  if [[ -f "${OCI_CONFIG}" ]]; then
    if oci iam region-subscription list >/dev/null 2>&1; then
      say_ok "$(t doctor.oci.auth_ok)"
      oci_ok=1
    else
      say_miss "$(t doctor.oci.auth_fail)"
      say_hint "$(t doctor.oci.auth_hint1)"
      say_hint "$(t doctor.oci.auth_hint2 "${OCI_CONFIG}")"
    fi
  fi
else
  say_warn "$(t doctor.oci.cli_missing)"
  say_hint "$(t doctor.oci.cli_hint1)"
  say_hint "$(t doctor.oci.cli_hint2)"
fi

# =============================================================================================
# 3. Configuración de tu server
# =============================================================================================

say_title "$(t doctor.title.3)"

if [[ -f "${TFVARS}" ]]; then
  say_ok "infra/terraform/envs/prod/terraform.tfvars"
  if grep -q 'CAMBIAME' "${TFVARS}"; then
    say_miss "$(t doctor.tfvars.placeholder)"
    say_hint "$(t doctor.tfvars.placeholder_hint)"
  fi
  for clave in tenancy_ocid admin_cidr ssh_public_key alert_email server_password; do
    if [[ -z "$(tfvar "${clave}")" ]]; then
      say_miss "$(t doctor.tfvars.key_missing "${clave}")"
      say_hint "$(t doctor.setup_hint)"
    fi
  done
  perms="$(stat -c '%a' "${TFVARS}" 2>/dev/null || echo '')"
  if [[ -n "${perms}" && "${perms}" != "600" ]]; then
    say_warn "$(t doctor.tfvars.perms "${perms}")"
    say_hint "$(t doctor.tfvars.perms_hint "${TFVARS}")"
  fi
else
  say_miss "$(t doctor.tfvars.missing)"
  say_hint "$(t doctor.setup_hint)"
fi

if [[ -f "${ENV_FILE}" ]]; then
  say_ok ".env"
else
  say_warn "$(t doctor.env.missing)"
  say_hint "$(t doctor.env.hint)"
fi

MODS_FILE="${REPO_DIR}/config/mods.txt"
if [[ -f "${MODS_FILE}" ]]; then
  mods_n="$(grep -cE '^[[:space:]]*[0-9]+' "${MODS_FILE}" || true)"
  if [[ "${mods_n}" -gt 0 ]]; then
    say_ok "$(t doctor.mods.count "${mods_n}")"
  else
    say_ok "$(t doctor.mods.vanilla)"
    say_hint "$(t doctor.mods.vanilla_hint)"
  fi
else
  say_warn "$(t doctor.mods.missing)"
  say_hint "$(t doctor.mods.missing_hint)"
fi
if [[ -f "${REPO_DIR}/config/servertest_SandboxVars.lua" ]]; then
  say_ok "config/servertest_SandboxVars.lua"
else
  say_warn "$(t doctor.sandbox.missing)"
  say_hint "$(t doctor.sandbox.hint)"
fi

# --- El repo tiene que estar accesible desde la máquina de la nube ------------------------------
repo_url="$(tfvar repo_url)"
if [[ -n "${repo_url}" ]]; then
  if [[ "${repo_url}" == https://* ]]; then
    if GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      git ls-remote "${repo_url}" HEAD >/dev/null 2>&1; then
      say_ok "$(t doctor.repo.public "${repo_url}")"
    else
      say_miss "$(t doctor.repo.private "${repo_url}")"
      say_hint "$(t doctor.repo.private_hint1)"
      say_hint "$(t doctor.repo.private_hint2)"
    fi
  else
    say_ok "$(t doctor.repo.ssh "${repo_url}")"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      slug="${repo_url#git@github.com:}"
      slug="${slug%.git}"
      if gh repo deploy-key list -R "${slug}" >/dev/null 2>&1; then
        if [[ -n "$(gh repo deploy-key list -R "${slug}" 2>/dev/null)" ]]; then
          say_ok "$(t doctor.repo.key_ok)"
        else
          say_warn "$(t doctor.repo.key_missing)"
          say_hint "$(t doctor.repo.key_hint)"
        fi
      fi
    fi
  fi
else
  say_warn "$(t doctor.repo.unreadable)"
fi

# =============================================================================================
# 4. Estado del server en la nube (solo si ya lo desplegaste)
# =============================================================================================

instance_ocid="$(tofu_output instance_ocid "${TF_RE_OCID}")"

if [[ -z "${instance_ocid}" ]]; then
  say_title "$(t doctor.title.4)"
  say_ok "$(t doctor.cloud.none)"
  say_hint "$(t doctor.cloud.none_hint)"
else
  say_title "$(t doctor.title.4)"
  public_ip="$(tofu_output public_ip "${TF_RE_IP}")"
  say_ok "$(t doctor.cloud.ip "${public_ip:-$(t doctor.cloud.ip_unknown)}")"

  if [[ "${oci_ok}" -eq 1 ]]; then
    estado="$(oci compute instance get --instance-id "${instance_ocid}" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    case "${estado}" in
      RUNNING)
        say_ok "$(t doctor.cloud.running)"
        say_hint "$(t doctor.cloud.running_hint)"
        ;;
      STOPPED)
        say_ok "$(t doctor.cloud.stopped)"
        say_hint "$(t doctor.cloud.stopped_hint)"
        ;;
      "")
        say_warn "$(t doctor.cloud.state_unknown)"
        say_hint "$(t doctor.cloud.state_hint "${instance_ocid}")"
        ;;
      *) say_warn "$(t doctor.cloud.state_other "${estado}")" ;;
    esac

    bucket="$(tofu_output bucket_name "${TF_RE_NOMBRE}")"
    ns="$(tofu_output bucket_namespace "${TF_RE_NOMBRE}")"
    if [[ -n "${bucket}" && -n "${ns}" ]]; then
      ultimo="$(oci os object list --bucket-name "${bucket}" --namespace "${ns}" \
        --fields timeCreated --query 'sort_by(data, &"time-created")[-1].name' \
        --raw-output 2>/dev/null || true)"
      if [[ -n "${ultimo}" && "${ultimo}" != "null" ]]; then
        say_ok "$(t doctor.backup.last "${ultimo}")"
      else
        say_warn "$(t doctor.backup.none "${bucket}")"
        say_hint "$(t doctor.backup.none_hint)"
      fi
    fi
  else
    say_warn "$(t doctor.cloud.no_oci)"
  fi
fi

# =============================================================================================
# Resumen
# =============================================================================================

if [[ "${PROBLEMAS}" -eq 0 ]]; then
  [[ "${QUIET}" -eq 1 ]] || printf '%s\n\n' "$(t doctor.final.ok)"
  exit 0
fi

printf '%s\n\n' "$(t doctor.final.problems "${PROBLEMAS}")"
exit 1
