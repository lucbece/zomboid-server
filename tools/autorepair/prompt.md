El servidor de Project Zomboid que administras esta caido y el watchdog automatico ya intento
arreglarlo sin exito. Sos el ultimo recurso antes de despertar a una persona.

## Que paso

- Motivo detectado por el watchdog: **{{MOTIVO}}**
- Es la escalacion numero **{{INTENTOS}}** de hoy por este mismo motivo.
- Bundle de diagnostico: `{{BUNDLE_DIR}}`

Antes que nada, leelo entero. Contiene:

| Archivo | Que tiene |
|---|---|
| `motivo.txt` | Que detecto el watchdog y cuando |
| `log-contenedor.txt` | Las ultimas 800 lineas del log del server |
| `mods-errores.txt` | Las lineas del log sobre mods que faltan o fallan |
| `mods.txt` | La lista de mods declarada (copia de `config/mods.txt`) |
| `docker-inspect.json` | Estado del contenedor, incluido `RestartCount` |
| `df.txt`, `free.txt` | Disco y memoria en el momento de la falla |
| `journal-zomboid.txt` | Ultimas 100 lineas del journal de la unit |
| `journal-oom.txt` | Mensajes del kernel sobre el OOM killer |
| `servertest.ini` | La configuracion efectiva, con las passwords tachadas |

## Que ya intento el watchdog

Segun el motivo, alguna de estas cosas, y no alcanzo:

- **rcon**: reinicio limpio con `WARN_SECONDS=0 ./scripts/restart.sh`.
- **crash-loop**, **patron-fatal**, **oom**: `./scripts/stop.sh`, bundle, `make up`, y espero
  hasta 5 minutos a que apareciera `SERVER STARTED` en el log.
- **disco**: borro los backups locales de mas de un dia, los logs del juego de mas de 7 dias y
  corrio `docker system prune -f`.

Si el motivo es un cupo agotado (por ejemplo "ya se hicieron 2 reinicios en la ultima hora"),
el watchdog directamente no volvio a tocar nada.

## Tu objetivo

Que el server vuelva a arrancar **con el mundo intacto**: que aparezca `*** SERVER STARTED ****`
en `make logs` y que `./scripts/rcon.sh players` responda.

Un mundo perdido es peor que un server caido. Si la unica forma de levantarlo que se te ocurre
implica borrar o restaurar la partida, **no lo hagas**: terminá el informe explicando eso.

## Como trabajar

1. Leé el bundle y formá una hipotesis concreta antes de tocar nada.
2. Verificala en el log actual (`docker compose logs --tail 200 zomboid`) y en `config/`.
3. Aplicá el arreglo minimo y reinicia con `./scripts/restart.sh`.
4. Esperá y comproba: `docker compose logs --tail 50 zomboid` y `./scripts/rcon.sh players`.
5. Como maximo **3 intentos**. Si al tercero no arranco, pará y escribi el informe.

## Informe final

Terminá con un mensaje corto (se publica tal cual en el Discord de los jugadores) con:

- **Que encontre**: la causa, en una o dos frases, sin jerga innecesaria.
- **Que hice**: los cambios concretos, archivo por archivo.
- **Estado**: si el server esta arriba o no.
- **Que queda para el humano**: lo que no pudiste o no debiste hacer, y como revisar tus cambios.

Si desactivaste un mod, decilo con nombre y numero: alguien va a tener que decidir si lo saca
del todo o si espera una actualizacion del autor.
