# zomboid-server

Servidor dedicado de Project Zomboid **Build 42** (rama estable de Steam desde 2026-07-29, versión 42.20.x) para 8-16 jugadores, dockerizado, con config en git y deploy a una VM en la nube.

## Leer primero
- `PLAN.md`: decisiones tomadas, fases y criterios de aceptación. No re-litigar las decisiones de §1.
- `docs/research/`: investigación con fuentes. Consultar antes de buscar en la web:
  - `01-b42-server-install.md`: steamcmd, flags, puertos, heap, rutas, systemd.
  - `02-docker-and-tooling.md`: imágenes Docker, por qué Danixu, backups, IaC existente.
  - `03-cloud-hosting.md`: proveedores, precios (2026-09-03), latencia desde Buenos Aires.
  - `04-server-config-and-mods.md`: claves de `servertest.ini`, SandboxVars, spawn, mods, comandos admin, problemas comunes.
- `docs/runbook.md`: operación en la nube (alta de la cuenta OCI, deploy, backups, wipe, troubleshooting).

## Hechos fijos
- App ID del server: `380870`. Rama Steam pública = B42; **no** usar `-beta`. B41 = `-beta legacy41`.
- Imagen: `danixu86/project-zomboid-dedicated-server` con `SELF_MANAGED_MODS=1`, pinneada por digest `sha256:a98b0f219f63ad9f08b0658cf77c2c165705ab8d74775fd3db6e50fd6f4961e1` (trae el juego adentro, 42.20.4). Entrypoint auditado en `docs/research/02-docker-and-tooling.md` §7: solo reescribe `RCONPassword` y `UDPPort` con nuestra config.
- Datos del server dentro del contenedor: `/home/steam/Zomboid` (bind mount `./data/zomboid`). Workshop: `/home/steam/pz-dedicated/steamapps/workshop` (bind mount `./data/workshop`).
- Puertos: `16261-16262/udp` juego, `27015/tcp` RCON (solo admin). `8766-8767/udp` opcional.
- Nombre del server: `servertest` (no cambiar; nombra todos los archivos de config).
- `Mods=` = IDs de `mod.info` separados por `;` (load order). `WorkshopItems=` = IDs numéricos separados por `;`. Prefijo `\` por ID: **verificado empíricamente en 42.20.4 el 2026-09-03, es indiferente** (con y sin prefijo el mod carga igual); el repo usa la forma sin prefijo. Detalle en `docs/mods.md`.

## Hechos de la nube (Fase 2: código listo, `tofu apply` pendiente)
- Proveedor **Oracle Cloud, región `sa-saopaulo-1`** (Brazil East / São Paulo). El plan decía Vinhedo; se cambió el 2026-09-03 porque el alta de la cuenta no ofreció esa región.
- **Rutas en la VM**: repo en `/opt/zomboid-server`, datos en `/opt/zomboid-server/data/zomboid`, backups locales en `/opt/zomboid-server/backups`, logs de cron en `/var/log/zomboid/`. Unit systemd en `/etc/systemd/system/zomboid.service` (instalada desde `infra/systemd/`).
- **Usuario de la VM: `pz`** (grupos `docker` y `sudo`, sudo sin password). El `ubuntu` de la imagen de OCI también queda, con la key de metadata.
- El `.env` de la VM lo genera **cloud-init desde `terraform.tfvars`**, no se sincroniza con `make sync` ni se commitea. Las passwords están validadas en el módulo: 8-64 caracteres sin espacios, comillas, backslash ni `$` (el `.env` lo parsean bash y docker compose, que no escapan igual).
- La VM escribe el bucket de backups por **instance principal** (`rclone` con `provider = instance_principal_auth`): no hay ninguna credencial de OCI en el disco.
- **Deploy key**: la genera OpenTofu (`tls_private_key` ed25519); la pública sale en el output `deploy_public_key` y hay que cargarla a mano en GitHub antes del primer boot, o cloud-init falla al clonar.
- La IP pública es un `oci_core_public_ip` **RESERVED** atado a la private IP de la VNIC (`assign_public_ip = false`): sobrevive los stop/start de la Fase 3.

## Cómo validar sin credenciales (todo esto pasa hoy)
- OpenTofu está en `~/.local/bin/tofu` (v1.12.6, checksum verificado; no hay sudo en `lucpc`).
  ```bash
  tofu -chdir=infra/terraform/envs/prod init      # descarga oracle/oci y hashicorp/tls
  tofu -chdir=infra/terraform/envs/prod validate  # -> Success! The configuration is valid.
  tofu fmt -check -recursive infra/terraform
  ```
  **No correr `plan` ni `apply`**: necesitan `~/.oci/config` y crean recursos pagos.
- `infra/cloud-init.yaml` es un **template de `templatefile()`**: `${...}` lo reemplaza Tofu, un `$` literal se escribe `$$`. Para validarlo hay que renderizarlo primero (una config descartable con un solo `output` que llame a `templatefile(...)` con valores de ejemplo) y después:
  ```bash
  docker run --rm -v "$PWD:/mnt" ubuntu:24.04 bash -c \
    'apt-get update -qq && apt-get install -y -qq cloud-init >/dev/null &&
     cloud-init schema --config-file /mnt/rendered.yaml'
  ```
  (`cloud-init` no está en `lucpc` y no hay paquete pip oficial.)
- `.terraform.lock.hcl` **sí** se commitea (pin de providers). `terraform.tfvars`, `*.tfstate*` y `.terraform/` no.

## Reglas de trabajo
- **Nunca** commitear `.env`, `terraform.tfvars`, `*.tfstate`, `backups/` ni `config/servertest.ini` renderizado (solo el `.tpl`).
- **Nunca** parar el server con `docker stop`/`kill` directo: siempre RCON `save` + `quit` (`scripts/stop.sh`).
- La fuente de verdad de la config es `config/`. No editar a mano archivos dentro de `data/`.
- Los scripts son bash con `set -euo pipefail` y pasan `shellcheck` (en `lucpc` no está instalado: usar `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable scripts/*.sh scripts/lib/*.sh`). En esta shell Docker necesita `sg docker -c "..."`.
- `.env` lo parsean bash (`source`) y `docker compose`, que no escapan igual: valores con espacios entre comillas y un backslash literal solo como `"\\"`.
- No pushear ni crear PRs sin pedido explícito. Sin atribución de IA en commits.
- **El server local está apagado y no se levanta** (`lucpc` tiene pocos recursos): la validación end-to-end se hace en la nube. Docker solo para shellcheck, hadolint y validaciones.
- Si pzwiki devuelve 403, usar `https://r.jina.ai/https://pzwiki.net/wiki/<Pagina>`.
- Al terminar una fase, actualizar `PLAN.md` (marcar tareas hechas) y el `README.md`.
