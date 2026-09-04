#!/usr/bin/env bash
# Verifica que los catalogos de mensajes del CLI esten sanos. Lo corre el CI en el mismo job
# que el linter de shell (.github/workflows/ci.yml).
#
#   scripts/i18n-check.sh
#
# Chequea tres cosas:
#   1. los dos catalogos definen exactamente el mismo juego de claves
#   2. toda clave literal que se usa como `t <clave>` en setup.sh, scripts/ y el Makefile
#      existe en el catalogo
#   3. ningun valor tiene un placeholder de printf que no sea %s, %d o %%
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

ES="${REPO_DIR}/scripts/lib/i18n/es.sh"
EN="${REPO_DIR}/scripts/lib/i18n/en.sh"

fallas=0
fallo() {
  echo "i18n-check: ERROR: $*" >&2
  fallas=$((fallas + 1))
}

[[ -f "${ES}" ]] || fallo "no existe ${ES}"
[[ -f "${EN}" ]] || fallo "no existe ${EN}"
[[ "${fallas}" -eq 0 ]] || exit 1

claves() { sed -n -E 's/^MSG\[([^]]+)\]=.*/\1/p' "$1" | sort; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- 1. mismo juego de claves en los dos catalogos ---------------------------------------------
claves "${ES}" > "${tmp}/es.keys"
claves "${EN}" > "${tmp}/en.keys"

if ! diff -u "${tmp}/en.keys" "${tmp}/es.keys" > "${tmp}/diff"; then
  fallo "los catalogos no definen las mismas claves (- solo en en.sh, + solo en es.sh):"
  sed -n '3,$p' "${tmp}/diff" | grep -E '^[+-]' >&2 || true
fi

for f in "${tmp}/es.keys" "${tmp}/en.keys"; do
  if uniq -d "${f}" | grep -q .; then
    fallo "claves repetidas en $(basename "${f}" .keys).sh: $(uniq -d "${f}" | tr '\n' ' ')"
  fi
done

n_claves="$(wc -l < "${tmp}/en.keys" | tr -d ' ')"

# --- 2. toda clave literal usada como `t <clave>` existe ----------------------------------------
# Se buscan solo claves literales (con punto): `t "$var"` y compania no se pueden verificar.
mapfile -t fuentes < <(
  printf '%s\n' "${REPO_DIR}/setup.sh" "${REPO_DIR}/Makefile"
  find "${REPO_DIR}/scripts" -name '*.sh' -type f | sort
)

usadas="${tmp}/usadas"
: > "${usadas}"
for f in "${fuentes[@]}"; do
  [[ -f "${f}" ]] || continue
  # Los catalogos no usan `t`, solo lo definen.
  case "${f}" in */scripts/lib/i18n/*) continue ;; esac
  grep -hoE '(^|[^A-Za-z0-9_.])t "?[a-z][a-z0-9_]*(\.[a-z0-9_-]+)+"?' "${f}" \
    | sed -E 's/^[^A-Za-z]*t "?//; s/"$//' >> "${usadas}" || true
done
sort -u "${usadas}" -o "${usadas}"

n_usadas="$(wc -l < "${usadas}" | tr -d ' ')"
faltantes="$(comm -23 "${usadas}" "${tmp}/en.keys")"
if [[ -n "${faltantes}" ]]; then
  fallo "claves usadas con \`t\` que no estan en el catalogo:"
  while IFS= read -r clave; do echo "  ${clave}" >&2; done <<<"${faltantes}"
fi

# --- 3. placeholders de printf validos ----------------------------------------------------------
# El valor de cada clave se le pasa a printf como formato: un % que no sea %s, %d o %% rompe
# el mensaje (o peor, se come un argumento).
for f in "${EN}" "${ES}"; do
  malos="$(awk '
    /^MSG\[/ { clave = $0; sub(/^MSG\[/, "", clave); sub(/\].*/, "", clave) }
    /^#/ { next }
    clave == "" { next }
    {
      linea = $0
      while ((i = index(linea, "%")) > 0) {
        sig = substr(linea, i + 1, 1)
        if (sig != "s" && sig != "d" && sig != "%") { print clave; break }
        linea = substr(linea, i + 2)
      }
    }' "${f}" | sort -u)"
  if [[ -n "${malos}" ]]; then
    fallo "$(basename "${f}"): valores con un %% que no es %%s, %%d ni %%%% en: $(tr '\n' ' ' <<<"${malos}")"
  fi
done

if [[ "${fallas}" -ne 0 ]]; then
  echo "i18n-check: ${fallas} problema(s)." >&2
  exit 1
fi

echo "i18n-check: OK. ${n_claves} claves en cada catalogo, ${n_usadas} usadas literalmente con 't'."
