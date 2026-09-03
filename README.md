# zomboid-server

Servidor dedicado de **Project Zomboid Build 42** (42.20.4) para jugar con amigos (8-16 jugadores),
con mods, corriendo en Docker. Toda la configuración de la partida vive en `config/` y está
versionada en git.

Estado: **Fase 1 hecha** — el server corre reproducible en local (`lucpc`). Fases 2 (nube) y 3
(on-demand + bot de Discord) pendientes. Ver `PLAN.md`.

---

## Requisitos

- `docker` y el plugin `docker compose` v2+. Si `docker compose version` falla, instalar el plugin
  para el usuario (no hace falta root):
  ```bash
  mkdir -p ~/.docker/cli-plugins
  curl -fsSL -o ~/.docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
  chmod +x ~/.docker/cli-plugins/docker-compose
  ```
- El usuario tiene que estar en el grupo `docker` (`sudo usermod -aG docker $USER` + volver a
  loguearse).
- `make`, `gettext-base` (para `envsubst`), y `gcc` + `git` si hace falta compilar `mcrcon`.
- ~15 GB de disco (la imagen trae el juego adentro: 10.4 GB) y al menos 10 GB de RAM libre con
  `MAX_MEMORY=8g`.

## Arranque desde cero

```bash
cp .env.example .env      # completar ADMINPASSWORD, RCONPASSWORD y SERVER_PASSWORD
make mcrcon               # compila ./bin/mcrcon si no hay uno en el sistema
make up                   # render de la config + docker compose up -d
make logs                 # el server está arriba cuando aparece "*** SERVER STARTED ****"
```

El primer arranque genera el mundo y baja los mods del Workshop: **2-4 minutos**. Los siguientes
tardan ~30 segundos (medido: 26 s desde `up` hasta `SERVER STARTED`).

## Uso diario

| Comando | Qué hace |
|---|---|
| `make up` | Renderiza `config/` + `.env` a `data/zomboid/Server/` y levanta el server |
| `make down` | Apagado limpio: aviso por chat, `save`, `quit` por RCON, espera a que el contenedor salga |
| `make restart` | `down` + re-render + `up`. Es la forma de aplicar cambios de mods o del ini |
| `make logs` | Sigue el log del server |
| `make status` | Estado del contenedor + jugadores conectados |
| `make rcon CMD=players` | Cualquier comando de admin por RCON |
| `make render` | Solo re-renderiza la config, sin tocar el server |

Ejemplos de RCON (`make rcon CMD='...'`):

```bash
make rcon CMD=players
make rcon CMD='servermsg "reinicio en 5 minutos"'
make rcon CMD='setaccesslevel "pepe" admin'
make rcon CMD=save
make rcon CMD=showoptions
```

> **Nunca** apagar con `docker stop`, `docker kill` ni `docker compose down` a secas: el server no
> guarda el mundo si lo matan. Siempre `make down`.

## Conectarse desde el cliente de Steam

El server escucha en **UDP 16261 y 16262**. `Public=false`, así que **no aparece en el server
browser**: hay que agregarlo a mano.

En el cliente de Project Zomboid (Build 42, la rama estable — sin beta):

1. Menú principal → **Join** (Unirse).
2. Pestaña **Favorites** (Favoritos) → botón **Add server** / **Añadir servidor** (abajo).
3. Completar:
   - **Name / Nombre**: lo que quieras (`Zomboid de los pibes`).
   - **IP**: `127.0.0.1` si jugás en la misma PC que corre el server; la IP LAN de `lucpc`
     (**`192.168.1.8`** en la red actual, verificar con `ip -4 addr`) desde otra máquina de la casa.
   - **Port / Puerto**: `16261`.
   - **Account username / Nombre de cuenta**: el nombre con el que querés jugar. Se crea solo la
     primera vez (`Open=true`).
   - **Account password / Contraseña de cuenta**: la tuya, la elegís vos, es por jugador.
   - **Server password / Contraseña del servidor**: el valor de `SERVER_PASSWORD` de `.env`.
4. **Save** y después **Join**.

Para que entren desde fuera de la LAN hay que exponer 16261-16262/udp (eso es la Fase 2, en la
nube). El puerto de RCON (27015/tcp) está bindeado a `127.0.0.1` a propósito: no se expone nunca.

Darse admin adentro del juego, una vez conectado con tu usuario:

```bash
make rcon CMD='setaccesslevel "tu_usuario" admin'
```

(El usuario `admin` con la `ADMINPASSWORD` de `.env` también existe y ya es admin.)

## Cambiar la partida

- **Mods**: editar `config/mods.txt` (una línea `workshop_id  mod_id  # nombre`) y `make restart`.
  Procedimiento completo, cómo sacar los IDs y el resultado empírico del prefijo `\`: `docs/mods.md`.
- **Reglas de la partida** (zombies, loot, clima, XP): `config/servertest_SandboxVars.lua`.
  **Definirlas antes del primer arranque del mundo real**: varias quedan fijadas al crear la
  partida y cambiarlas después no aplica.
- **Spawns**: `config/servertest_spawnregions.lua` y `config/servertest_spawnpoints.lua`.
- **Resto del server** (PVP, backups, chat, anticheat, Discord): `config/servertest.ini.tpl`.
  Los secretos van como `${VAR}` y se inyectan desde `.env`.

Después de cualquier cambio: `make restart`. Para cambios de ini que soporten recarga en caliente,
alcanza con `make rcon CMD=reloadoptions`.

## Estructura

```
config/                     # fuente de verdad de la partida (esto es lo que se edita)
  servertest.ini.tpl        #   ini con ${PLACEHOLDERS} para secretos
  servertest_SandboxVars.lua
  servertest_spawnregions.lua
  servertest_spawnpoints.lua
  mods.txt                  #   lista de mods -> genera Mods= y WorkshopItems=
scripts/
  render-config.sh          # config/ + .env -> data/zomboid/Server/
  rcon.sh                   # wrapper de mcrcon
  stop.sh                   # apagado limpio (save + quit)
  restart.sh                # stop + render + up
  build-mcrcon.sh           # compila ./bin/mcrcon
data/                       # gitignored: bind mounts del contenedor
  zomboid/                  #   /home/steam/Zomboid  (Server/, Saves/, Logs/, db/, backups/)
  workshop/                 #   mods bajados del Workshop
bin/                        # gitignored: mcrcon compilado
docs/
  mods.md                   # cómo agregar/quitar mods
  research/                 # investigación con fuentes
```

## Qué nunca se commitea

`.env`, `data/`, `bin/`, `config/servertest.ini` (el renderizado; sí se commitea el `.tpl`).

## Backups

Por ahora solo los nativos del server: `BackupsCount=5`, `BackupsPeriod=60`, `BackupsOnStart=true`,
en `data/zomboid/backups/`. Los backups a object storage con `rclone` son de la Fase 2.

Para un backup manual rápido:

```bash
make rcon CMD=save
sleep 5
tar czf ~/zomboid-$(date +%F-%H%M).tar.gz -C data/zomboid Saves/Multiplayer/servertest Server
```

## Documentación

- `PLAN.md`: plan por fases, decisiones tomadas y criterios de aceptación.
- `docs/mods.md`: mods.
- `docs/research/`: investigación con fuentes (instalación B42, Docker + verificación del
  entrypoint, hosting, config y mods).
