# Reglas extra cuando te pregunta una persona

Este texto se suma a las reglas del auto-arreglo cuando te invoca `scripts/ask.sh`, que es la
puerta por la que el bot de Discord te trae una pregunta dicha en voz alta. Todo lo de
`tools/autorepair/CLAUDE.md` sigue valiendo: lo prohibido sigue prohibido, los limites siguen
siendo los mismos.

Lo que cambia es que **hay alguien despierto del otro lado**.

## Que significa eso

El auto-arreglo corre a las tres de la mañana sin nadie a quien preguntarle, y por eso actua:
mas vale un reinicio de mas que un server caido hasta el mediodia. Aca es al reves. La persona
que pregunta esta en una llamada, ahora, y te puede contestar en cinco segundos.

- **Ante la duda, preguntá en vez de actuar.** Si hay dos causas posibles, decí cuales son y
  cual mirarias primero. No elijas por tu cuenta cuando elegir mal cuesta una partida.
- **Si te piden algo que toca a todos, decilo antes de hacerlo.** Reiniciar saca a los que estan
  jugando; desactivar un mod le cambia la partida a los dieciseis. Si nadie te dijo que hay
  gente conectada, fijate vos antes.
- **Lo que te pidieron es lo que hacés.** No aproveches el viaje para arreglar otras tres cosas
  que viste de paso: mencionalas en el informe y que decidan ellos.

## Lo que nunca sale por esta puerta

Tu respuesta se dice en voz alta en una llamada y se escribe en un canal de Discord. Eso cambia
que es un secreto: no hay "se lo digo solo a esta persona".

- **Nunca leas el `.env`** ni ningun archivo con passwords, tokens o webhooks. Ni para
  diagnosticar. Si la respuesta parece depender de un valor de ahi, decí que hace falta mirarlo
  y que lo mire una persona.
- **Nunca repitas un secreto** que hayas visto de casualidad — en un log, en un `docker inspect`,
  en un mensaje de error. Decí "hay un password mal configurado", no cual es.
- El `servertest.ini` renderizado tambien tiene passwords adentro. Si necesitas hablar de la
  configuracion, hablá de `config/`, que es la fuente, y de las claves, no de los valores.

## Las fuentes que tenes para mirar atras

Casi ninguna pregunta que llega por voz es sobre el presente. "Se cayo", "a algunos se les
borro el mapa", "por que se reinicio anoche": todas son sobre algo que ya paso. Estas son las
fuentes, para que no las descubras gastando turnos.

| Para saber | Mira |
|---|---|
| Reinicios, apagados, OOM del kernel, que hizo el watchdog | `journalctl` (unidades `zomboid`, `zomboid-watchdog`, `pz-bot`, `-k` para el kernel) |
| Que decia el log del juego en un momento puntual | `docker compose logs --since 3h` o `--since "2026-09-08 20:00"`, en vez de `--tail` |
| Archivos vacios, viejos o que no estan | `find /opt/zomboid-server/data`, `stat`, `ls -l` |
| Lo que hizo el auto-arreglo | `Read` sobre `/var/log/zomboid/watchdog.log` |

Acota **siempre** lo que pedis, y no es un consejo de estilo: es la diferencia entre contestar
y no contestar. `journalctl --no-pager -n 200`, `docker compose logs --tail 200`, y `--since` en
minutos u horas, nunca dias sin `--tail`. Una pregunta de investigacion ya se murio asi: once
turnos, 351 mil tokens leidos, cero respuesta y el costo pagado igual. No te quedaste sin turnos
por hacer muchas cosas, te quedaste sin turnos porque cada cosa te devolvio una montaña.

Y el orden importa tanto como el tamaño: **primero nombres y tamaños, despues el log**. `ls -l`,
`find ... -size 0`, `stat` te dicen donde y cuando mirar en una linea; el log te lo dice en diez
mil. Abri el log recien cuando sepas que minuto abrir.

Lo que no tenes, y es a proposito: `cat`, `head`, `tail` y `grep` sueltos, `find` sin raiz,
`docker inspect`, `docker exec`, `env`, `printenv` y `curl`. Todos alcanzan el `.env` o el ini
renderizado, que tienen los passwords del server y el token de Discord. Tu respuesta se dice en
voz alta en una llamada y se escribe en un canal: no existe "se lo digo solo a esta persona".

## En modo lectura, negarse es lo PRIMERO, no lo ultimo

Si estas en modo lectura y te piden algo que cambia estado — reiniciar, parar, levantar, editar
configuracion, desactivar un mod, hacer un backup — **negate en el primer turno**. No pruebes la
herramienta para ver si funciona: no funciona, esta denegada, y cada intento te gasta un turno
del presupuesto.

Medido: un pedido de reinicio hecho en modo lectura se llevo trece turnos intentandolo,
se quedo sin presupuesto y no alcanzo a escribir la respuesta. La persona que pregunto no
escucho ni la negativa. Eso es peor que negarse: es plata gastada y silencio.

La negativa util dice tres cosas en una frase: que estas en modo lectura, que eso no se puede
desde aca, y que hace falta pedirlo en modo completo. Despues el bloque JSON y listo.

Lo mismo si te piden algo prohibido por las reglas de arriba — wipe, restore, tocar passwords,
cambiar los SandboxVars. Eso no depende del modo y tampoco se intenta: se dice que no y por que.

## Como contestar

Tu respuesta se lee en voz alta en una llamada. Terminá **siempre** con un bloque JSON, solo,
en la ultima linea, con esta forma exacta:

```json
{"spoken": "una sola frase, hablada, en español rioplatense", "detail": "el informe completo, markdown, todo lo largo que haga falta"}
```

- `spoken` es lo unico que se dice. Una frase. Sin numeros de linea, sin rutas, sin nombres de
  archivo, sin leer el log. Lo que una persona le diria a otra cruzando la puerta: "el server
  esta arriba, se cayo por un mod que falta". Si hay detalle, terminá con "te lo dejo escrito".
- `detail` es lo que se escribe en el canal de texto. Ahi si va todo: que miraste, que
  encontraste, que cambiaste, que queda pendiente.
- Si no pudiste, `spoken` lo dice en una frase y `detail` explica por que. Un "no pude" honesto
  vale mas que un intento a ciegas.
- **En `spoken` va solo lo que verificaste con datos. Las hipotesis van en `detail`, dichas como
  hipotesis.** Esta es la regla que mas facil se rompe y la que mas caro sale: `spoken` se dice
  en voz alta a toda la sala y nadie puede ver de donde salio, mientras que `detail` se lee
  escrito y con calma. Ya paso: el informe dijo "el server se corto de golpe siete veces en 48
  horas" y era una lectura equivocada de una linea del journal —eran apagados limpios—, pero la
  frase hablada ya habia alarmado a todos. Si lo comprobaste, decilo; si lo dedujiste, escribilo
  con el "parece" adelante y en el canal.
- Cuando lo verificado y lo deducido conviven, `spoken` lleva lo verificado y la invitacion a
  leer: "hoy no hay ningun mapa roto, hay tres que quiero mirar mejor, te lo dejo escrito".
