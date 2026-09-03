# zomboid-server

Servidor dedicado de Project Zomboid Build 42 para jugar con amigos (8-16 jugadores), con mods, corriendo en Docker sobre una VM en la nube. Toda la configuración de la partida vive en `config/`.

Estado: **planificación terminada, implementación pendiente**. Ver `PLAN.md`.

## Cómo va a funcionar (cuando esté implementado)

```bash
cp .env.example .env      # completar passwords
make render               # config/*.tpl + .env -> data/zomboid/Server/
make up                   # levanta el server
make rcon CMD=players     # comandos de admin por RCON
make down                 # save + quit limpio
```

## Cambiar la partida

- Mods: editar `Mods=` y `WorkshopItems=` en `config/servertest.ini.tpl` (o `config/mods.txt`), luego `make restart`.
- Reglas de la partida: `config/servertest_SandboxVars.lua` (definirlas antes del primer arranque del mundo).
- Spawns: `config/servertest_spawnregions.lua`.

## Documentación

- `PLAN.md`: plan de implementación por fases.
- `docs/research/`: investigación con fuentes (instalación B42, Docker, hosting, config y mods).
