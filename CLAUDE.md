# zomboid-server

Servidor dedicado de Project Zomboid **Build 42** (rama estable de Steam desde 2026-07-29, versión 42.20.x) para 8-16 jugadores, dockerizado, con config en git y deploy a una VM en la nube.

## Leer primero
- `PLAN.md`: decisiones tomadas, fases y criterios de aceptación. No re-litigar las decisiones de §1.
- `docs/research/`: investigación con fuentes. Consultar antes de buscar en la web:
  - `01-b42-server-install.md`: steamcmd, flags, puertos, heap, rutas, systemd.
  - `02-docker-and-tooling.md`: imágenes Docker, por qué Danixu, backups, IaC existente.
  - `03-cloud-hosting.md`: proveedores, precios (2026-09-03), latencia desde Buenos Aires.
  - `04-server-config-and-mods.md`: claves de `servertest.ini`, SandboxVars, spawn, mods, comandos admin, problemas comunes.

## Hechos fijos
- App ID del server: `380870`. Rama Steam pública = B42; **no** usar `-beta`. B41 = `-beta legacy41`.
- Imagen: `danixu86/project-zomboid-dedicated-server` con `SELF_MANAGED_MODS=1`, pinneada por digest `sha256:a98b0f219f63ad9f08b0658cf77c2c165705ab8d74775fd3db6e50fd6f4961e1` (trae el juego adentro, 42.20.4). Entrypoint auditado en `docs/research/02-docker-and-tooling.md` §7: solo reescribe `RCONPassword` y `UDPPort` con nuestra config.
- Datos del server dentro del contenedor: `/home/steam/Zomboid` (bind mount `./data/zomboid`). Workshop: `/home/steam/pz-dedicated/steamapps/workshop` (bind mount `./data/workshop`).
- Puertos: `16261-16262/udp` juego, `27015/tcp` RCON (solo admin). `8766-8767/udp` opcional.
- Nombre del server: `servertest` (no cambiar; nombra todos los archivos de config).
- `Mods=` = IDs de `mod.info` separados por `;` (load order). `WorkshopItems=` = IDs numéricos separados por `;`. Prefijo `\` por ID: **verificado empíricamente en 42.20.4 el 2026-09-03, es indiferente** (con y sin prefijo el mod carga igual); el repo usa la forma sin prefijo. Detalle en `docs/mods.md`.

## Reglas de trabajo
- **Nunca** commitear `.env`, `terraform.tfvars`, `*.tfstate` ni `config/servertest.ini` renderizado (solo el `.tpl`).
- **Nunca** parar el server con `docker stop`/`kill` directo: siempre RCON `save` + `quit` (`scripts/stop.sh`).
- La fuente de verdad de la config es `config/`. No editar a mano archivos dentro de `data/`.
- Los scripts son bash con `set -euo pipefail` y pasan `shellcheck` (en `lucpc` no está instalado: usar `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable scripts/*.sh`).
- `.env` lo parsean bash (`source`) y `docker compose`, que no escapan igual: valores con espacios entre comillas y un backslash literal solo como `"\\"`.
- No pushear ni crear PRs sin pedido explícito. Sin atribución de IA en commits.
- Si pzwiki devuelve 403, usar `https://r.jina.ai/https://pzwiki.net/wiki/<Pagina>`.
- Al terminar una fase, actualizar `PLAN.md` (marcar tareas hechas) y el `README.md`.
